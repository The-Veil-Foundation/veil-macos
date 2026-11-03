#!/usr/bin/env bash
# Builds Veil and packages it into a proper macOS .app bundle so the
# SwiftUI window and Dock icon appear correctly, then launches it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

# Prefer the released Xcode over a beta seed left selected by `xcode-select`.
# The SDK the binary links against decides whether the app gets the current
# macOS look, so a stale toolchain is a visible regression, not a detail.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

CONFIG="${1:-release}"
BUILD_NAME="XrayClient"      # SPM product (binary) name
APP_NAME="Veil"             # user-facing app + bundle name
APP_DIR="${ROOT}/${APP_NAME}.app"
VERSION="$(cat "${ROOT}/VERSION")"   # single source of truth, see Scripts/set-version.sh

echo "Building (${CONFIG})..."
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)"

MIN_MACOS="14.0"

# Stamp the SDK the app was actually compiled against.
#
# macOS decides whether an app gets the current look (Liquid Glass) or the
# legacy one from the SDK version recorded in the executable's LC_BUILD_VERSION.
# SwiftPM under Xcode 27 records the *deployment target* there (14.0), so a
# locally built app came out looking like a macOS 15 app no matter which Xcode
# built it. `vtool` rewrites that field; the minimum stays where it was, so the
# app still runs on macOS 14.
stamp_sdk_version() {
  local binary="$1"
  local sdk
  sdk="$(xcrun --show-sdk-version 2>/dev/null || true)"
  [ -n "${sdk}" ] || return 0
  xcrun vtool -set-build-version macos "${MIN_MACOS}" "${sdk}" -replace \
    -output "${binary}" "${binary}" >/dev/null 2>&1 || true
}

echo "Assembling ${APP_NAME}.app..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

# Executable (renamed to the user-facing app name).
cp "${BIN_PATH}/${BUILD_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
stamp_sdk_version "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# Bundled resources (the xray and sing-box binaries live in the SPM resource bundle).
BUNDLE="${BIN_PATH}/${BUILD_NAME}_${BUILD_NAME}.bundle"
if [ -d "${BUNDLE}" ]; then
  cp -R "${BUNDLE}" "${APP_DIR}/Contents/Resources/"
fi

# Privileged helper payload. Nothing here runs until the user installs it from
# Settings, which copies it to a root-owned directory after one admin prompt.
HELPER_DIR="${APP_DIR}/Contents/Library/VeilHelper"
mkdir -p "${HELPER_DIR}"
cp "${BIN_PATH}/VeilHelper" "${HELPER_DIR}/VeilHelper"
stamp_sdk_version "${HELPER_DIR}/VeilHelper"
if [ -f "${ROOT}/Sources/XrayClient/Resources/tun2socks" ]; then
  cp "${ROOT}/Sources/XrayClient/Resources/tun2socks" "${HELPER_DIR}/tun2socks"
fi
# The routing core runs as root when the native TUN inbound is used, so the
# helper gets its own copy: root must not execute a binary inside a bundle the
# user can write to.
if [ -f "${ROOT}/Sources/XrayClient/Resources/sing-box" ]; then
  cp "${ROOT}/Sources/XrayClient/Resources/sing-box" "${HELPER_DIR}/sing-box"
fi
cp "${ROOT}/Scripts/install-daemon.sh" "${HELPER_DIR}/install-daemon.sh"
cp "${ROOT}/Scripts/uninstall-daemon.sh" "${HELPER_DIR}/uninstall-daemon.sh"
chmod +x "${HELPER_DIR}"/* 2>/dev/null || true

# App icon, if present.
ICON_LINE=""
if [ -f "${ROOT}/Resources/AppIcon.icns" ]; then
  cp "${ROOT}/Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
  ICON_LINE="  <key>CFBundleIconFile</key><string>AppIcon</string>"
fi
# The Liquid Glass icon, compiled from Resources/AppIcon.icon by make-icon.sh.
if [ -f "${ROOT}/Resources/Assets.car" ]; then
  cp "${ROOT}/Resources/Assets.car" "${APP_DIR}/Contents/Resources/Assets.car"
  ICON_LINE="${ICON_LINE}
  <key>CFBundleIconName</key><string>AppIcon</string>"
fi

# Info.plist (LSUIElement=false so it shows in the Dock with a window)
cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>dev.local.veil</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
${ICON_LINE}
  <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>Veil uses the camera to scan server QR codes.</string>
  <key>LSUIElement</key><false/>
</dict>
</plist>
PLIST

# Ad-hoc sign so the app and the bundled xray binary run locally.
codesign --force --deep --sign - "${APP_DIR}" 2>/dev/null || true

# `open` on a bundle that is already running only activates the old process,
# so every rebuild during development kept showing the previous binary.
if pgrep -f "${APP_DIR}/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1; then
  echo "Quitting the running ${APP_NAME}..."
  # Ask politely first: a plain SIGTERM skips applicationWillTerminate, which
  # is where the tunnel is torn down, and would leave routes behind.
  osascript -e "tell application id \"dev.local.veil\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 25); do
    pgrep -f "${APP_DIR}/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1 || break
    sleep 0.2
  done
  pkill -f "${APP_DIR}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
  for _ in $(seq 1 30); do
    pgrep -f "${APP_DIR}/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1 || break
    sleep 0.2
  done
fi

echo "Launching ${APP_NAME}.app..."
open "${APP_DIR}"
echo "Done. App bundle at: ${APP_DIR}"
