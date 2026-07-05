#!/bin/bash
# Builds Resources/AppIcon.icns from "BUTTER CLASS ICON.tiff" for the app
# bundle, Dock, Finder, and window chrome.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SOURCE="$PROJECT_DIR/BUTTER CLASS ICON.tiff"
if [ ! -f "$SOURCE" ]; then
    SOURCE="$PROJECT_DIR/Icon Work/BUTTER CLASS ICON.tiff"
fi
ICONSET="$PROJECT_DIR/Sources/ButterClassifier/Resources/AppIcon.iconset"
OUT="$PROJECT_DIR/Sources/ButterClassifier/Resources/AppIcon.icns"

if [ ! -f "$SOURCE" ]; then
    echo "error: icon source not found: $SOURCE" >&2
    exit 1
fi

mkdir -p "$PROJECT_DIR/Sources/ButterClassifier/Resources"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

make_png() {
    local size=$1
    local name=$2
    sips -s format png -z "$size" "$size" "$SOURCE" --out "$ICONSET/$name" >/dev/null
}

make_png 16  icon_16x16.png
make_png 32  icon_16x16@2x.png
make_png 32  icon_32x32.png
make_png 64  icon_32x32@2x.png
make_png 128 icon_128x128.png
make_png 256 icon_128x128@2x.png
make_png 256 icon_256x256.png
make_png 512 icon_256x256@2x.png
make_png 512 icon_512x512.png
make_png 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$ICONSET"
echo "==> Wrote $OUT"
