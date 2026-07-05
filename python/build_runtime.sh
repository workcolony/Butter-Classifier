#!/bin/bash
# Builds a fully relocatable Python runtime in Runtime/python containing all
# dependencies needed by audio_analyzer.py. The result is copied into the app
# bundle at build time, so end users never install anything.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RUNTIME_DIR="$PROJECT_DIR/Runtime"
DOWNLOADS_DIR="$SCRIPT_DIR/downloads"

PBS_TAG="20260623"
PBS_ASSET="cpython-3.12.13+${PBS_TAG}-aarch64-apple-darwin-install_only_stripped.tar.gz"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${PBS_ASSET}"

mkdir -p "$DOWNLOADS_DIR"

if [ ! -f "$DOWNLOADS_DIR/$PBS_ASSET" ]; then
    echo "==> Downloading python-build-standalone ${PBS_TAG}..."
    curl -L -o "$DOWNLOADS_DIR/$PBS_ASSET" "$PBS_URL"
fi

if [ ! -x "$RUNTIME_DIR/python/bin/python3" ]; then
    echo "==> Extracting Python runtime..."
    rm -rf "$RUNTIME_DIR"
    mkdir -p "$RUNTIME_DIR"
    tar -xzf "$DOWNLOADS_DIR/$PBS_ASSET" -C "$RUNTIME_DIR"
fi

PY="$RUNTIME_DIR/python/bin/python3"
echo "==> Python: $("$PY" --version)"

echo "==> Installing dependencies..."
"$PY" -m pip install --upgrade pip --quiet
"$PY" -m pip install -r "$SCRIPT_DIR/requirements.txt"

SITE_PACKAGES="$("$PY" -c 'import site; print(site.getsitepackages()[0])')"

# The essentia arm64 wheel's bundled ffmpeg dylibs reference SDL2 at the
# Homebrew path. Copy the dylib into the runtime and rewrite the references
# so the runtime works on machines without Homebrew.
echo "==> Fixing external dylib references..."
FIXUP_LIB_DIR="$RUNTIME_DIR/python/lib/butter-fixup"
mkdir -p "$FIXUP_LIB_DIR"

find "$SITE_PACKAGES" -name '*.dylib' -o -name '*.so' | while read -r lib; do
    otool -L "$lib" 2>/dev/null | awk 'NR>1 {print $1}' | grep -E '^(/opt/homebrew|/usr/local)' | while read -r dep; do
        depname="$(basename "$dep")"
        if [ ! -f "$FIXUP_LIB_DIR/$depname" ]; then
            if [ -f "$dep" ]; then
                echo "    bundling $dep"
                cp "$dep" "$FIXUP_LIB_DIR/$depname"
                # Give the copied lib a self-contained id and fix its own deps too
                install_name_tool -id "@loader_path/$depname" "$FIXUP_LIB_DIR/$depname" 2>/dev/null || true
                codesign -f -s - "$FIXUP_LIB_DIR/$depname" 2>/dev/null || true
            else
                echo "    WARNING: $lib references missing $dep"
                continue
            fi
        fi
        rel="$("$PY" -c "import os; print(os.path.relpath('$FIXUP_LIB_DIR', os.path.dirname('$lib')))")"
        install_name_tool -change "$dep" "@loader_path/$rel/$depname" "$lib"
        codesign -f -s - "$lib" 2>/dev/null || true
    done
done

echo "==> Checking for remaining external references..."
LEFTOVER=$(find "$SITE_PACKAGES" \( -name '*.dylib' -o -name '*.so' \) -exec otool -L {} + 2>/dev/null | grep -E '^\s+(/opt/homebrew|/usr/local)' | sort -u || true)
if [ -n "$LEFTOVER" ]; then
    echo "WARNING: external references remain:"
    echo "$LEFTOVER"
else
    echo "    OK: no Homebrew//usr/local references remain."
fi

echo "==> Verifying imports..."
"$PY" -c "import numpy, scipy, librosa, yaml, soundfile, wavinfo; import essentia, essentia.standard; print('All imports OK. essentia', essentia.__version__)"

echo "==> Runtime ready at $RUNTIME_DIR/python"
