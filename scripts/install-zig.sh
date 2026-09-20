#!/bin/bash
set -euo pipefail
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'Apple Silicon macOS is required.' >&2; exit 1; }
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
zig_version="$(python3 "$script_dir/check-versions.py" --zig-version)"
zig_sha="$(python3 "$script_dir/check-versions.py" --zig-sha256)"
zig_dir="${1:-$PWD/.tools}"
mkdir -p "$zig_dir"
zig_dir="$(cd "$zig_dir" && pwd)"
archive="$(mktemp -t cghostty-zig)"
trap 'rm -f "$archive"' EXIT
curl --fail --location --retry 3 "https://ziglang.org/download/$zig_version/zig-aarch64-macos-$zig_version.tar.xz" --output "$archive"
echo "$zig_sha  $archive" | shasum -a 256 --check --status
tar -xJf "$archive" -C "$zig_dir"
printf '%s\n' "$zig_dir/zig-aarch64-macos-$zig_version"
