//! Custom geosite overlay import (enhanced-honk adblock channel).
//!
//! The adblock engine generates a small v2ray `geosite.dat` holding a `honk-ads`
//! category on the router itself, then POSTs only a short JSON pointer to it.
//! honk validates the file, swaps it into its runtime data directory
//! atomically, and asks the existing configuration coordinator for a normal
//! reload. No hosts file is written, no SIGHUP is sent, and the shipped
//! `geosite.dat` (and therefore the original domestic / overseas split) is
//! left untouched: the overlay is concatenated at matcher build time in
//! `routing::geo`.
//!
//! A path is used instead of a binary body because the native API caps every
//! request at 64 KiB; a 270k-domain ad list is several MiB. The endpoint is
//! covered by the native API's normal resource() auth, so it requires the same
//! secret as config import / geodata update.

use std::sync::Arc;

use axum::body::to_bytes;
use axum::extract::Request;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde::Deserialize;
use serde_json::json;
use sha2::{Digest, Sha256};

use super::{ApiError, ErrorCode, NativeState, config, parse_query, types::RequestId};
use crate::routing::{GEOSITE_OVERLAY_NAME, validate_overlay};

const MAX_POINTER_BYTES: usize = 4096;
/// An adblock list is a few MB at most; 64 MiB leaves generous headroom while
/// keeping a hostile request from filling the router's flash.
const MAX_OVERLAY_BYTES: u64 = 64 * 1024 * 1024;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ImportRequest {
    /// Absolute path to a v2ray geosite DAT readable by honk.
    path: String,
    /// Optional hex sha256 of the file; checked before anything is installed.
    #[serde(default)]
    sha256: Option<String>,
}

fn invalid(message: &'static str) -> ApiError {
    ApiError::new(
        StatusCode::BAD_REQUEST,
        ErrorCode::InvalidRequest,
        message,
        None,
    )
}

fn unsupported(message: &'static str) -> ApiError {
    ApiError::new(
        StatusCode::FORBIDDEN,
        ErrorCode::PermissionDenied,
        message,
        None,
    )
}

fn unavailable(message: &'static str) -> ApiError {
    ApiError::new(
        StatusCode::SERVICE_UNAVAILABLE,
        ErrorCode::TemporarilyUnavailable,
        message,
        None,
    )
}

/// Only directories an administrator or an embedded generator legitimately
/// uses for this overlay. Rejecting `..` keeps a symlinked path inside one of
/// these roots from escaping it after canonicalization.
fn permitted(path: &std::path::Path, data_dir: &std::path::Path) -> bool {
    use std::path::Component;
    if !path.is_absolute()
        || path
            .components()
            .any(|part| matches!(part, Component::ParentDir))
    {
        return false;
    }
    let Ok(canonical) = path.canonicalize() else {
        return false;
    };
    let roots = [
        data_dir.to_path_buf(),
        std::path::PathBuf::from("/tmp"),
        std::path::PathBuf::from("/etc/honk"),
        std::path::PathBuf::from("/var/lib/honk"),
    ];
    roots.iter().any(|root| canonical.starts_with(root))
}

/// POST `{"path":"/tmp/honk-ads.dat","sha256":"..."}`. The file must be a
/// structurally valid geosite DAT. A failed validation leaves the currently
/// installed overlay and the running generation untouched.
pub(super) async fn import(
    state: &Arc<NativeState>,
    request: Request,
    id: &RequestId,
) -> Result<Response, ApiError> {
    parse_query(request.uri(), &[], id)?;
    if !state.observation.configuration.writable() {
        return Err(unsupported("Configuration administration is not permitted"));
    }

    let body = to_bytes(request.into_body(), MAX_POINTER_BYTES)
        .await
        .map_err(|_| {
            ApiError::new(
                StatusCode::PAYLOAD_TOO_LARGE,
                ErrorCode::RequestTooLarge,
                "Overlay import pointer exceeds 4096 bytes.",
                None,
            )
        })?;
    let pointer: ImportRequest = serde_json::from_slice(&body).map_err(|_| {
        ApiError::new(
            StatusCode::BAD_REQUEST,
            ErrorCode::InvalidRequest,
            "Expected {\"path\":\"...\",\"sha256\":\"...\"}.",
            None,
        )
    })?;

    let data_dir = honk_config::paths::data_dir();
    let source = std::path::PathBuf::from(&pointer.path);
    if !permitted(&source, &data_dir) {
        return Err(unsupported(
            "Overlay path is outside the permitted directories.",
        ));
    }
    let meta = tokio::fs::metadata(&source)
        .await
        .map_err(|_| invalid("Overlay file does not exist."))?;
    if !meta.is_file() || meta.len() == 0 || meta.len() > MAX_OVERLAY_BYTES {
        return Err(invalid("Overlay file is empty, not a file, or too large."));
    }

    let expected = pointer.sha256;
    let (bytes, sha256, final_path) = tokio::task::spawn_blocking(move || {
        let bytes = std::fs::read(&source).map_err(|_| ())?;
        let digest = Sha256::digest(&bytes);
        let sha256 = digest
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        if let Some(expected) = &expected {
            if !expected.eq_ignore_ascii_case(&sha256) {
                return Err(());
            }
        }
        validate_overlay(&bytes).map_err(|_| ())?;
        let final_path = data_dir.join(GEOSITE_OVERLAY_NAME);
        let tmp_path = data_dir.join(format!(".{GEOSITE_OVERLAY_NAME}.tmp"));
        std::fs::write(&tmp_path, &bytes).map_err(|_| ())?;
        std::fs::rename(&tmp_path, &final_path).map_err(|_| ())?;
        Ok::<(Vec<u8>, String, std::path::PathBuf), ()>((bytes, sha256, final_path))
    })
    .await
    .map_err(|_| unavailable("Overlay writer task failed"))?
    .map_err(|_| {
        ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            ErrorCode::UnsupportedValue,
            "Overlay sha256 mismatch, invalid geosite DAT, or could not be installed.",
            None,
        )
    })?;

    // Reuse honk's own reload operation: it reserves, deduplicates by
    // idempotency key, validates the new generation before switching, and
    // publishes the usual operation receipt for the caller to poll.
    let reload_request = Request::builder()
        .method("POST")
        .uri("/api/v1/operations/reload")
        .body(axum::body::Body::empty())
        .map_err(|_| invalid("Could not build reload request"))?;
    let reload = config::reload(state, reload_request, id).await?;
    let reload_status = reload.status().as_u16();
    let body = json!({
        "status": "imported",
        "category": "honk-ads",
        "asset": "geosite",
        "sha256": sha256,
        "size_bytes": bytes.len(),
        "path": final_path.to_string_lossy(),
        "reload_status": reload_status,
    });
    Ok((StatusCode::OK, axum::Json(body)).into_response())
}
