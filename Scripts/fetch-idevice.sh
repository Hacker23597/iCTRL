#!/bin/bash
# Fetch the idevice xcframework (MIT, github.com/jkcoxson/idevice).
#
# Not committed: the release ships ~230MB static archives per slice and the
# xcframework is only published as a release asset, not in the repo tree — so
# SPM can't resolve it by URL either. We pull it once and keep only the iOS
# device slice, which is the only one the runner/app ever ships.
set -euo pipefail

VERSION="${IDEVICE_VERSION:-v0.1.65}"
DEST="$(cd "$(dirname "$0")/.." && pwd)/Frameworks/IDevice.xcframework"
URL="https://github.com/jkcoxson/idevice/releases/download/${VERSION}/idevice-xcframework-${VERSION}.zip"

if [ -f "$DEST/ios-arm64/libidevice_ffi.a" ]; then
    echo "✅ IDevice.xcframework already present ($DEST)"
    exit 0
fi

echo "⬇️  Fetching idevice ${VERSION} (~215MB)…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fL --progress-bar -o "$TMP/idevice.zip" "$URL"
unzip -q "$TMP/idevice.zip" -d "$TMP/x"

SRC="$TMP/x/swift/IDevice.xcframework/ios-arm64"
[ -d "$SRC" ] || { echo "❌ ios-arm64 slice missing from the release archive"; exit 1; }

mkdir -p "$DEST/ios-arm64"
cp -R "$SRC/." "$DEST/ios-arm64/"

/usr/bin/python3 - "$DEST/Info.plist" <<'PY'
import plistlib, sys
plistlib.dump({
    "AvailableLibraries": [{
        "LibraryIdentifier": "ios-arm64",
        "LibraryPath": "libidevice_ffi.a",
        "HeadersPath": "Headers",
        "SupportedArchitectures": ["arm64"],
        "SupportedPlatform": "ios",
    }],
    "CFBundlePackageType": "XFWK",
    "XCFrameworkFormatVersion": "1.0",
}, open(sys.argv[1], "wb"))
PY

echo "✅ IDevice.xcframework ready ($(du -sh "$DEST" | cut -f1), iOS arm64 only)"
