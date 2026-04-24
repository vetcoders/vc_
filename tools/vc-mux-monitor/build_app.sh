#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

APP_NAME="VCMuxMonitor"
APP_DIR="${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"

echo "Building VCMuxMonitor..."
swiftc VcMuxMonitor.swift -o VCMuxMonitor -O

echo "Creating App Bundle structure..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"

mv VCMuxMonitor "${MACOS_DIR}/"

cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>VCMuxMonitor</string>
    <key>CFBundleIdentifier</key>
    <string>space.div0.vcmuxmonitor</string>
    <key>CFBundleName</key>
    <string>VCMuxMonitor</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

echo "Creating DMG..."
DMG_NAME="${APP_NAME}.dmg"
rm -f "${DMG_NAME}"
hdiutil create -volname "${APP_NAME}" -srcfolder "${APP_DIR}" -ov -format UDZO "${DMG_NAME}"

echo "Done! Created ${APP_DIR} and ${DMG_NAME}"
