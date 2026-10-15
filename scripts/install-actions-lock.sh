#!/bin/bash
# Install the official extension binary without modifying gh's global extensions.
set -euo pipefail
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'Apple Silicon macOS is required.' >&2; exit 1; }
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool_record="$(python3 - "$script_dir/actions-lock-toolchain.json" <<'PY'
import json
from pathlib import Path
import re
import sys

record = json.loads(Path(sys.argv[1]).read_text())
version, digest = record['version'], record['sha256']
if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'[0-9a-f]{64}', digest):
    raise SystemExit('Invalid actions-lock toolchain record')
print(version, digest)
PY
)"
read -r tool_version tool_sha <<< "$tool_record"
tool_dir="${1:-$PWD/.tools}/gh-actions-lock-$tool_version"
mkdir -p "$tool_dir"
tool_dir="$(cd "$tool_dir" && pwd)"
binary="$tool_dir/gh-actions-lock"
if [[ ! -f "$binary" ]] || ! echo "$tool_sha  $binary" | shasum -a 256 --check --status; then
    download="$(mktemp "$tool_dir/.download.XXXXXX")"
    trap 'rm -f "$download"' EXIT
    curl --fail --location --retry 3 "https://github.com/github/gh-actions-lock/releases/download/v$tool_version/darwin-arm64" --output "$download"
    echo "$tool_sha  $download" | shasum -a 256 --check --status
    chmod 755 "$download"
    mv -f "$download" "$binary"
fi
printf '%s\n' "$binary"
