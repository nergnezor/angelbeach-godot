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

if [ "${1:-}" = "--release" ]; then
    cargo build --release
    stage target/release/libangelbeach.so ../bin/libangelbeach.release.so
else
    cargo build
    stage target/debug/libangelbeach.so ../bin/libangelbeach.debug.so
fi
