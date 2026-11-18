#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Nimbscape"
APP_BUNDLE="${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"
VOLUME_NAME="${APP_NAME}"
BG_FILE="Resources/dmg-background.tiff"
VOL_ICON="Resources/AppIcon.icns"
STAGING_DIR="build/dmg-staging"
TEMP_DMG="build/${APP_NAME}-temp.dmg"
DEVICE=""

cleanup() {
    if [ -n "${DEVICE}" ]; then
        hdiutil detach "${DEVICE}" -quiet 2>/dev/null || hdiutil detach "${DEVICE}" -force -quiet 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [ ! -d "${APP_BUNDLE}" ]; then
    echo "Error: ${APP_BUNDLE} not found. Run ./build.sh --no-open first."
    exit 1
fi

if [ ! -f "${BG_FILE}" ]; then
    echo "Error: ${BG_FILE} not found."
    exit 1
fi

if [ -d "/Volumes/${VOLUME_NAME}" ]; then
    hdiutil detach "/Volumes/${VOLUME_NAME}" -force -quiet 2>/dev/null || true
fi

echo "=== Packaging ${DMG_NAME} ==="
rm -rf "${STAGING_DIR}" "${TEMP_DMG}" "${DMG_NAME}"
mkdir -p "${STAGING_DIR}/.background"

cp -R "${APP_BUNDLE}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"
cp "${BG_FILE}" "${STAGING_DIR}/.background/background.tiff"

STAGING_KB=$(du -sk "${STAGING_DIR}" | awk '{print $1}')
DMG_SIZE_MB=$(( (STAGING_KB / 1024) + 24 ))

hdiutil create -volname "${VOLUME_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -size "${DMG_SIZE_MB}m" \
    -ov -format UDRW \
    -fs HFS+ \
    "${TEMP_DMG}" >/dev/null

MOUNT_OUTPUT=$(hdiutil attach -readwrite -noverify -noautoopen "${TEMP_DMG}")
DEVICE=$(echo "${MOUNT_OUTPUT}" | awk '/Apple_HFS/ {print $1; exit}')
MOUNT_POINT=$(echo "${MOUNT_OUTPUT}" | awk -F'\t' '/\/Volumes\// {print $NF; exit}')

if [ -z "${MOUNT_POINT}" ]; then
    echo "Error: failed to mount ${TEMP_DMG}"
    exit 1
fi

osascript <<EOF
tell application "Finder"
    tell disk "${VOLUME_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {180, 140, 840, 588}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "${APP_BUNDLE}" of container window to {180, 215}
        set position of item "Applications" of container window to {480, 215}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF

if [ -f "${VOL_ICON}" ]; then
    cp "${VOL_ICON}" "${MOUNT_POINT}/.VolumeIcon.icns"
    if command -v SetFile >/dev/null 2>&1; then
        SetFile -a V "${MOUNT_POINT}/.VolumeIcon.icns" || true
        SetFile -a C "${MOUNT_POINT}" || true
    fi
fi

sync
hdiutil detach "${DEVICE}" >/dev/null
DEVICE=""

hdiutil convert "${TEMP_DMG}" -format UDZO -imagekey zlib-level=9 -o "${DMG_NAME}" >/dev/null
rm -rf "${STAGING_DIR}" "${TEMP_DMG}"

echo "=== DMG Created: ${DMG_NAME} ==="
