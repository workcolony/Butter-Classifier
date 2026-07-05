#!/bin/bash
# Builds ButterClassifier.app: compiles the Swift app in release mode and
# assembles the bundle with the analyzer script + relocatable Python runtime
# inside Resources, so the app is fully self-contained.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

APP_NAME="ButterClassifier"
APP_DIR="$PROJECT_DIR/build/$APP_NAME.app"

if [ ! -x "$PROJECT_DIR/Runtime/python/bin/python3" ]; then
    echo "Runtime not built yet; running python/build_runtime.sh first..."
    "$PROJECT_DIR/python/build_runtime.sh"
fi

if [ -d "/Applications/Xcode.app" ]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

echo "==> Building Swift app (release)..."
swift build -c release

echo "==> Assembling $APP_NAME.app..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/analyzer"

cp ".build/release/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.butterclassifier.app</string>
    <key>CFBundleName</key>
    <string>Butter Classifier</string>
    <key>CFBundleDisplayName</key>
    <string>Butter Classifier</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string></string>
</dict>
</plist>
PLIST

echo "==> Copying analyzer script + Python runtime (this is the big part)..."
cp python/analyzer/*.py "$APP_DIR/Contents/Resources/analyzer/"
cp -R Runtime/python "$APP_DIR/Contents/Resources/analyzer/python"

echo "==> Ad-hoc signing..."
codesign --force --deep -s - "$APP_DIR" 2>/dev/null || codesign --force -s - "$APP_DIR"

echo "==> Done: $APP_DIR"
du -sh "$APP_DIR"
