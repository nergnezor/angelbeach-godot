#!/usr/bin/env bash
# Build the native library and stage it where Godot watches for it.
#
# The .so does NOT live in rust/target/ as far as Godot is concerned. That tree
# is 1.4 GB across 1600+ files of cargo intermediates, and the editor rescans
# everything under res:// — so rust/ carries a .gdignore and the finished
# library is copied into bin/, which holds two files. The editor then watches
# exactly the thing that changes, which is what hot reload keys on.
#
#   ./build.sh                  linux debug  (the editor / acceptance slot)
#   ./build.sh --release        linux release
#   ./build.sh --android        android arm64 debug
#   ./build.sh --android --release
set -euo pipefail
cd "$(dirname "$0")/rust"

# bin/ is gitignored local state, absent on a fresh checkout (e.g. CI).
mkdir -p ../bin

# Stage by rename, never by overwrite. A running Godot -- the game, or the
# headless editor that serves the LSP -- has this .so mmap'd. `cp` rewrites
# the bytes under the same inode, so the next page fault into the file reads
# a page that no longer matches the mapping and the kernel kills the process
# with SIGBUS (exit 135). `mv` within bin/ is rename(2): the old inode stays
# alive for whoever already mapped it, and only new processes see the new
# file. Same fix that lets you replace a running binary on Linux.
stage() {
    local src=$1 dst=$2
    install -m 755 "$src" "$dst.new"
    mv -f "$dst.new" "$dst"
    echo "staged ${dst#../}"
}

ANDROID=0
RELEASE=0
for arg in "$@"; do
    case "$arg" in
        --android) ANDROID=1 ;;
        --release) RELEASE=1 ;;
        *)
            echo "unknown argument: $arg" >&2
            echo "usage: $0 [--android] [--release]" >&2
            exit 2
            ;;
    esac
done

if [ "$ANDROID" -eq 1 ]; then
    # NDK clang is the linker. cargo has no useful default for
    # aarch64-linux-android — without this it asks for a linker that is not
    # on PATH. ANDROID_NDK_HOME / ANDROID_NDK_ROOT, then $ANDROID_HOME/ndk/<one>.
    # API 24 matches Godot's own Vulkan min SDK, so the .so cannot demand a
    # newer libc than the APK will install on.
    NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
    if [ -z "$NDK" ]; then
        SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
        if [ -n "$SDK" ] && [ -d "$SDK/ndk" ]; then
            # Newest installed NDK. Godot 4.7 documents 28.1.13356709; a
            # neighbouring version still ships the same *-android24-clang
            # wrappers this script calls by name.
            NDK=$(find "$SDK/ndk" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n1)
        fi
    fi
    if [ -z "$NDK" ] || [ ! -d "$NDK" ]; then
        echo "Android NDK not found. Set ANDROID_NDK_HOME or install ndk;28.1.13356709 under ANDROID_HOME." >&2
        exit 1
    fi
    case "$(uname -s)" in
        Darwin) HOST=darwin-x86_64
            [ "$(uname -m)" = "arm64" ] && HOST=darwin-arm64
            ;;
        Linux)  HOST=linux-x86_64 ;;
        *)      echo "unsupported host for the Android NDK prebuilt: $(uname -s)" >&2; exit 1 ;;
    esac
    PREBUILT="$NDK/toolchains/llvm/prebuilt/$HOST"
    CLANG="$PREBUILT/bin/aarch64-linux-android24-clang"
    if [ ! -x "$CLANG" ]; then
        echo "missing $CLANG — this NDK does not ship the API-24 aarch64 wrapper" >&2
        exit 1
    fi
    export CLANG_PATH="$PREBUILT/bin/clang"
    export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$CLANG"
    export CC_aarch64_linux_android="$CLANG"
    export AR_aarch64_linux_android="$PREBUILT/bin/llvm-ar"
    rustup target add aarch64-linux-android >/dev/null
    if [ "$RELEASE" -eq 1 ]; then
        cargo build --release --target aarch64-linux-android
        stage target/aarch64-linux-android/release/libangelbeach.so \
            ../bin/libangelbeach.android.arm64.release.so
    else
        cargo build --target aarch64-linux-android
        stage target/aarch64-linux-android/debug/libangelbeach.so \
            ../bin/libangelbeach.android.arm64.debug.so
    fi
elif [ "$RELEASE" -eq 1 ]; then
    cargo build --release
    stage target/release/libangelbeach.so ../bin/libangelbeach.release.so
else
    cargo build
    stage target/debug/libangelbeach.so ../bin/libangelbeach.debug.so
fi
