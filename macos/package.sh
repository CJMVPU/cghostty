#!/bin/bash
# Package a previously built cghostty.app; publishing is handled separately.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-$repo_dir/macos/build/ReleaseLocal/cghostty.app}"
output_dir="${2:-$repo_dir/artifacts}"
[[ -d "$app" ]] || { echo "App not found: $app" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == com.cjmvpu.cghostty ]] || { echo 'Package the ReleaseLocal or Release application, not Debug.' >&2; exit 1; }
[[ "$(lipo -archs "$app/Contents/MacOS/cghostty")" == arm64 ]] || { echo 'Expected an arm64-only executable.' >&2; exit 1; }
version="$(/usr/libexec/PlistBuddy -c 'Print :CGhosttyVersion' "$app/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)*$ ]] || { echo 'Invalid bundle version.' >&2; exit 1; }
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
archive="$output_dir/cghostty-$version-macos-arm64.zip"
# Optional Developer ID distribution. Certificates/profile must already exist in the user's keychain.
if [[ -n "${CGHOSTTY_SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$CGHOSTTY_SIGN_IDENTITY" "$app/Contents/PlugIns/DockTilePlugin.plugin"
    codesign --force --options runtime --timestamp --entitlements "$repo_dir/macos/Ghostty.entitlements" --sign "$CGHOSTTY_SIGN_IDENTITY" "$app"
fi
codesign --verify --deep --strict "$app"
if [[ -n "${CGHOSTTY_NOTARY_PROFILE:-}" && -z "${CGHOSTTY_SIGN_IDENTITY:-}" ]]; then
    echo 'Notarization requires CGHOSTTY_SIGN_IDENTITY.' >&2; exit 1
fi
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
if [[ -n "${CGHOSTTY_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$archive" --keychain-profile "$CGHOSTTY_NOTARY_PROFILE" --wait
    xcrun stapler staple "$app"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
fi
(cd "$output_dir" && shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")
printf '%s\n' "$archive"
