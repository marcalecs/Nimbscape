#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "Error: swiftc not found. Install Xcode Command Line Tools first:"
    echo "  xcode-select --install"
    exit 1
fi

APP_NAME="Nimbscape"
BUILD_DIR="build"
APP_BUNDLE="${APP_NAME}.app"
ARCH="$(uname -m)"
INSTALL_TO_APPS=false
AUTO_OPEN=true

for arg in "$@"; do
    case "$arg" in
        --install) INSTALL_TO_APPS=true ;;
        --no-open) AUTO_OPEN=false ;;
    esac
done

echo "=== Building ${APP_NAME} (${ARCH}) ==="

rm -rf "${BUILD_DIR}" "${APP_BUNDLE}"
mkdir -p "${BUILD_DIR}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources/Presets"

echo "Compiling Swift sources..."
swiftc -O -swift-version 6 \
    -target "${ARCH}-apple-macosx14.0" \
    -framework Cocoa \
    -framework SwiftUI \
    -framework WebKit \
    -framework AVFoundation \
    -framework CoreGraphics \
    -framework CoreImage \
    -framework IOKit \
    -framework Carbon \
    -framework UniformTypeIdentifiers \
    -framework ScreenCaptureKit \
    -framework Accelerate \
    -framework ServiceManagement \
    -framework ImageIO \
    -framework CoreMedia \
    Sources/Models/*.swift \
    Sources/App/*.swift \
    Sources/Engine/*.swift \
    Sources/UI/*.swift \
    Sources/main.swift \
    -o "${BUILD_DIR}/${APP_NAME}"

echo "Packaging ${APP_BUNDLE}..."
cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_BUNDLE}/Contents/Info.plist"
if [ -f "Resources/AppIcon.icns" ]; then
    cp Resources/AppIcon.icns "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi
cp -R Presets/* "${APP_BUNDLE}/Contents/Resources/Presets/"

xattr -cr "${APP_BUNDLE}" 2>/dev/null || true
codesign --force --deep --sign - "${APP_BUNDLE}"

if [ "${INSTALL_TO_APPS}" = true ]; then
    echo "Installing to /Applications/${APP_BUNDLE}..."
    rm -rf "/Applications/${APP_BUNDLE}"
    cp -R "${APP_BUNDLE}" "/Applications/${APP_BUNDLE}"
    xattr -cr "/Applications/${APP_BUNDLE}" 2>/dev/null || true
    TARGET_APP="/Applications/${APP_BUNDLE}"
else
    TARGET_APP="${APP_BUNDLE}"
fi

echo "=== Build Successful: ${TARGET_APP} ==="

if [ "${AUTO_OPEN}" = true ]; then
    pkill -x "${APP_NAME}" 2>/dev/null || true
    sleep 0.3
    open "${TARGET_APP}"
fi
