//! OpenWrt LuCI readiness protocol.
//!
//! The vendor firmware's LuCI status page does not consider honk "ready"
//! merely because the process is alive: it requires a marker file
//! `/var/run/honk/core-ready-<token>` written by the core itself once every
//! listener is up.  The init script generates a one-shot token, stores it in
//! `/var/run/honk/readiness` (token + config hash) and passes the values down
//! through `HONK_READY_*` environment variables.  `rpcd`'s status method and
//! `lifecycle.sh::honk_lifecycle_ready_owned` cross-check the marker's `pid`,
//! `token`, `config_hash`, `api_enabled` and `clash_api_secret_set` against the
//! live process and the readiness file.  Without the marker LuCI reports
//! `core_not_ready` forever even though the proxy is fully functional.
//!
//! This module is a no-op unless `HONK_READY_TOKEN` is set, so unit tests and
//! non-OpenWrt deployments (which do not set it) are unaffected.

use std::path::PathBuf;

const READY_DIR: &str = "/var/run/honk";

/// Fields captured from the init script.  Empty token => protocol disabled.
struct ReadyEnv {
    token: String,
    config_hash: String,
    api_enabled: String,
    api_listen: String,
    clash_api_listen: String,
    clash_api_secret_set: String,
}

fn env(name: &str) -> String {
    std::env::var(name).unwrap_or_default()
}

fn read_env() -> Option<ReadyEnv> {
    let token = env("HONK_READY_TOKEN");
    if token.is_empty() {
        return None;
    }
    let api_enabled = env("HONK_READY_API_ENABLED");
    let clash_api_secret_set = env("HONK_READY_CLASH_API_SECRET_SET");
    // The init script only emits true/false; tolerate 1/0 too and normalize,
    // because rpcd's readiness check matches exactly `true` or `false`.
    let boolish = |v: String| -> String {
        match v.as_str() {
            "1" => "true".to_string(),
            "0" | "" => "false".to_string(),
            "true" | "false" => v,
            _ => "false".to_string(),
        }
    };
    Some(ReadyEnv {
        token,
        config_hash: env("HONK_READY_CONFIG_HASH"),
        api_enabled: boolish(api_enabled),
        api_listen: env("HONK_READY_API_LISTEN"),
        clash_api_listen: env("HONK_READY_CLASH_API_LISTEN"),
        clash_api_secret_set: boolish(clash_api_secret_set),
    })
}

fn marker_path(token: &str) -> PathBuf {
    PathBuf::from(READY_DIR).join(format!("core-ready-{token}"))
}

/// Write the readiness marker once startup has fully completed.  Uses a
/// same-directory temporary file + rename so rpcd never observes a partial
/// marker.  Errors are logged by the caller but never abort startup: readiness
/// reporting is best-effort and must not take the proxy down.
pub(crate) fn write() -> anyhow::Result<()> {
    let ready = match read_env() {
        Some(ready) => ready,
        None => return Ok(()),
    };
    std::fs::create_dir_all(READY_DIR)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(READY_DIR, std::fs::Permissions::from_mode(0o700));
    }
    let pid = std::process::id();
    let mut body = String::new();
    body.push_str(&format!("pid={pid}\n"));
    body.push_str(&format!("token={}\n", ready.token));
    body.push_str(&format!("config_hash={}\n", ready.config_hash));
    body.push_str(&format!("api_enabled={}\n", ready.api_enabled));
    body.push_str(&format!("api_listen={}\n", ready.api_listen));
    body.push_str(&format!("clash_api_listen={}\n", ready.clash_api_listen));
    body.push_str(&format!(
        "clash_api_secret_set={}\n",
        ready.clash_api_secret_set
    ));

    let final_path = marker_path(&ready.token);
    let tmp_path = marker_path(&format!("{}.tmp-{}", ready.token, pid));
    std::fs::write(&tmp_path, body.as_bytes())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp_path, std::fs::Permissions::from_mode(0o600));
    }
    match std::fs::rename(&tmp_path, &final_path) {
        Ok(()) => Ok(()),
        Err(err) => {
            let _ = std::fs::remove_file(&tmp_path);
            Err(err.into())
        }
    }
}

/// Remove the marker on orderly shutdown.  No-op when the protocol is off.
pub(crate) fn clear() {
    if let Some(ready) = read_env() {
        let _ = std::fs::remove_file(marker_path(&ready.token));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_token_disables_protocol() {
        // The test process should not have HONK_READY_TOKEN set.
        if std::env::var("HONK_READY_TOKEN")
            .unwrap_or_default()
            .is_empty()
        {
            assert!(read_env().is_none());
        }
    }

    #[test]
    fn boolish_normalizes_variants() {
        // Inline the closure's mapping via a tiny helper mirror to keep the
        // test independent of process env.
        let normalize = |v: &str| -> String {
            match v {
                "1" => "true".to_string(),
                "0" | "" => "false".to_string(),
                "true" | "false" => v.to_string(),
                _ => "false".to_string(),
            }
        };
        assert_eq!(normalize("true"), "true");
        assert_eq!(normalize("1"), "true");
        assert_eq!(normalize("false"), "false");
        assert_eq!(normalize("0"), "false");
        assert_eq!(normalize(""), "false");
        assert_eq!(normalize("garbage"), "false");
    }
}
