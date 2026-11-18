#!/bin/bash
set -e

echo "=== Building Nimbscape ==="

APP_NAME="Nimbscape"
BUILD_DIR="build"
APP_BUNDLE="${APP_NAME}.app"
ARCH="$(uname -m)"

rm -rf "${BUILD_DIR}" "${APP_BUNDLE}"
mkdir -p "${BUILD_DIR}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources/Presets"

echo "Compiling Swift sources (${ARCH})..."
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

echo "Packaging .app bundle..."
cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_BUNDLE}/Contents/Info.plist"
if [ -f "Resources/AppIcon.icns" ]; then
    cp Resources/AppIcon.icns "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi
cp -R Presets/* "${APP_BUNDLE}/Contents/Resources/Presets/"

codesign --force --deep --sign - "${APP_BUNDLE}"

echo "=== Build Successful: ${APP_BUNDLE} ==="
