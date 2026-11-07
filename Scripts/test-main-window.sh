#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/veil-window-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

APP="$TEST_DIR/WindowSmokeTest.app"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>WindowSmokeTest</string>
    <key>CFBundleIdentifier</key><string>org.veil.window-test.${TEST_DIR##*.}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
</dict>
</plist>
EOF

swiftc -swift-version 6 -parse-as-library \
    "$ROOT/Sources/XrayClient/Views/WindowID.swift" \
    "$ROOT/Tests/WindowSmokeTest.swift" \
    -o "$APP/Contents/MacOS/WindowSmokeTest"
"$APP/Contents/MacOS/WindowSmokeTest"
