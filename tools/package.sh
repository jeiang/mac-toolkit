#!/usr/bin/env bash
# Builds the release archives into DIST (default dist/). Run inside `nix develop` on macOS:
# both targets need the SDK frameworks.
#
# With CODESIGN_IDENTITY set (a "Developer ID Application" identity in the keychain), the app
# is signed with the hardened runtime. With NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID
# also set (an App Store Connect API key), it is notarized and the ticket stapled before it is
# zipped. Without them it keeps the linker's ad hoc signature.
set -euo pipefail

version=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' build.zig.zon)
dist=${1:-dist}
rm -rf "$dist" zig-out/release
mkdir -p "$dist"

for target in aarch64-macos x86_64-macos; do
    prefix="zig-out/release/$target"
    app="$prefix/mac-toolkit.app"
    zip="$dist/mac-toolkit-$version-$target.zip"
    zig build app -Dtarget="$target" -Doptimize=ReleaseSafe --prefix "$prefix"
    if [ -n "${CODESIGN_IDENTITY:-}" ]; then
        codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$app"
        codesign --verify --strict --verbose=2 "$app"
        if [ -n "${NOTARY_KEY_PATH:-}" ]; then
            ditto -c -k --keepParent "$app" "$zip"
            xcrun notarytool submit "$zip" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" \
                --issuer "$NOTARY_ISSUER_ID" --wait
            xcrun stapler staple "$app"
            spctl --assess --type execute --verbose=2 "$app"
        fi
    fi
    ditto -c -k --keepParent "$app" "$zip"
done

(cd "$dist" && shasum -a 256 -- * > SHA256SUMS)
