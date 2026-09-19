#!/bin/bash
set -euo pipefail
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'Apple Silicon macOS is required.' >&2; exit 1; }
zig_version=0.16.0
zig_sha=b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489
zig_dir="${1:-$PWD/.tools}"
mkdir -p "$zig_dir"
zig_dir="$(cd "$zig_dir" && pwd)"
archive="$(mktemp -t cghostty-zig)"
trap 'rm -f "$archive"' EXIT
curl --fail --location --retry 3 "https://ziglang.org/download/$zig_version/zig-aarch64-macos-$zig_version.tar.xz" --output "$archive"
echo "$zig_sha  $archive" | shasum -a 256 --check --status
tar -xJf "$archive" -C "$zig_dir"
printf '%s\n' "$zig_dir/zig-aarch64-macos-$zig_version"
