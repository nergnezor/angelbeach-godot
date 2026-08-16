#!/usr/bin/env bash
# Build the native library and stage it where Godot watches for it.
#
# The .so does NOT live in rust/target/ as far as Godot is concerned. That tree
# is 1.4 GB across 1600+ files of cargo intermediates, and the editor rescans
# everything under res:// — so rust/ carries a .gdignore and the finished
# library is copied into bin/, which holds two files. The editor then watches
# exactly the thing that changes, which is what hot reload keys on.
set -euo pipefail
cd "$(dirname "$0")/rust"
if [ "${1:-}" = "--release" ]; then
    cargo build --release
    cp -f target/release/libangelbeach.so ../bin/libangelbeach.release.so
    echo "staged bin/libangelbeach.release.so"
else
    cargo build
    cp -f target/debug/libangelbeach.so ../bin/libangelbeach.debug.so
    echo "staged bin/libangelbeach.debug.so"
fi
