#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
command -v cargo >/dev/null || { echo 'Rust 1.95+ required' >&2; exit 1; }
cargo ndk --version >/dev/null || { echo 'cargo-ndk required' >&2; exit 1; }
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to the installed Android NDK}"
# No download at app runtime. Cargo fetches only the pinned upstream
# workspace and its build dependencies at build time.
cargo ndk -t arm64-v8a -p 24 -o ../app/build/generated/dscRust/jniLibs build --release
test -s ../app/build/generated/dscRust/jniLibs/arm64-v8a/libfileshare_dsc.so
