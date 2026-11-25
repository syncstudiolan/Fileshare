#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
command -v cargo >/dev/null || { echo 'Rust 1.95+ required' >&2; exit 1; }
cargo ndk --version >/dev/null || { echo 'cargo-ndk required' >&2; exit 1; }
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to the installed Android NDK}"
# cargo-ndk 4.1.2 treats lowercase -p as Cargo's package selector.
# Use its long --platform option; keep all NDK aliases consistent.
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
export ANDROID_NDK="$ANDROID_NDK_HOME"
test -d "$ANDROID_NDK_HOME/toolchains/llvm"
# No download at app runtime. Cargo fetches only the pinned upstream
# workspace and its build dependencies at build time.
output="${1:?Pass Gradle-generated JNI output directory}"
mkdir -p "$output"
cargo ndk --target arm64-v8a --platform 24 --output-dir "$output" build --release
test -s "$output/arm64-v8a/libfileshare_dsc.so"
