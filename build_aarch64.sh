#!/bin/sh
# 交叉编译 honk-core 到 aarch64-unknown-linux-musl（真机 ImmortalWRT aarch64）
# 基于官方 Justfile 的 build-musl-native 配方，仅把 target 从 x86_64 换成 aarch64。
#
# 依赖（统一在 ~/tools，不散落）：
#   RUSTUP_HOME=/Users/chen/tools/rustup  CARGO_HOME=/Users/chen/tools/cargo
#   zig       = /Users/chen/tools/zig/zig
#   cmake     = /Users/chen/tools/cmake-venv/bin/cmake  (boring-sys)
#   bpf-linker= /Users/chen/tools/bpf-linker/bpf-linker (预编译，避免 llvm-config)
#   toolchains= 1.99.1 (用户态) + nightly-2026-10-20 (eBPF, +rust-src +llvm-tools)
set -eu

SRC=/Users/chen/WorkBuddy/2026-11-15-21-23-03/research/honk-src
ZIG=/Users/chen/tools/zig/zig
BPF_LINKER=/Users/chen/tools/bpf-linker/bpf-linker
export RUSTUP_HOME=/Users/chen/tools/rustup
export CARGO_HOME=/Users/chen/tools/cargo
# rust-toolchain.toml lists clippy; a partial toolchain makes rustup try to
# repair it and fail on a stale bin/cargo-clippy. Pin the installed toolchain.
export RUSTUP_TOOLCHAIN=1.99.1-aarch64-apple-darwin
# ci/zigcc / ci/zigcxx call `exec zig cc/c++`; boring-sys needs cmake. Put ci
# first so the zigcmake wrapper (GNU-format ar/ranlib) wins over system tools.
export PATH="$SRC/ci:$(dirname "$ZIG"):$(dirname "$BPF_LINKER"):/Users/chen/tools/cmake-venv/bin:$CARGO_HOME/bin:$PATH"
export GIT_CONFIG_GLOBAL=/Users/chen/tools/cargo/gitconfig

[ -x "$ZIG" ] || { echo "zig missing: $ZIG" >&2; exit 1; }
[ -x "$BPF_LINKER" ] || { echo "bpf-linker missing: $BPF_LINKER" >&2; exit 1; }
cd "$SRC"

# eBPF objects need nightly + build-std + bpf-linker to carry a .BTF section;
# honk-core's build.rs drives that step. Don't override its rustflags.
unset RUSTFLAGS

echo "== [1/2] ensure toolchains =="
python3 "$SRC/ci/patch_boring_sys.py"
rustup target list --installed | grep -q '^aarch64-unknown-linux-musl$' || \
  RUSTUP_DIST_SERVER=https://rsproxy.cn rustup target add aarch64-unknown-linux-musl
rustup toolchain list | grep -q 'nightly-2026-10-20' || \
  RUSTUP_DIST_SERVER=https://rsproxy.cn RUSTUP_UPDATE_ROOT=https://rsproxy.cn \
  rustup toolchain install nightly-2026-10-20 --profile minimal -c rust-src -c llvm-tools

echo "== [2/2] build honk-core aarch64-unknown-linux-musl =="
ZIGCC_TARGET=aarch64-linux-musl \
CC_aarch64_unknown_linux_musl="$SRC/ci/zigcc" \
CXX_aarch64_unknown_linux_musl="$SRC/ci/zigcxx" \
AR_aarch64_unknown_linux_musl="$SRC/ci/zigar" \
RANLIB_aarch64_unknown_linux_musl="$SRC/ci/zigranlib" \
CMAKE="$SRC/ci/zigcmake" \
AR="$SRC/ci/zigar" \
RANLIB="$SRC/ci/zigranlib" \
CMAKE_AR="$SRC/ci/zigar" \
CMAKE_RANLIB="$SRC/ci/zigranlib" \
CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="$SRC/ci/zigcc" \
CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="-C link-self-contained=no" \
BINDGEN_EXTRA_CLANG_ARGS="$($SRC/ci/zig-bindgen-env aarch64-linux-musl)" \
cargo build --release -p honk-core \
  --no-default-features --features "ebpf,native-api,rprx,jemalloc" \
  --target aarch64-unknown-linux-musl

OUT="$SRC/target/aarch64-unknown-linux-musl/release/honk-core"
echo "BUILD_OK $OUT"
"$ZIG" strip "$OUT" 2>/dev/null || true
ls -la "$OUT"
