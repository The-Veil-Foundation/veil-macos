#!/bin/bash
# install-daemon.sh — installs the Veil privileged helper as a LaunchDaemon.
#
# Run as root, once, from the app (one admin prompt). Replaces the old
# sudoers-based install: there is no NOPASSWD rule, no root-owned shell script
# that the app invokes, and no state in /tmp.
#
# Args:
#   $1 = payload directory inside the app bundle (VeilHelper, tun2socks, scripts)
#   $2 = path to the Veil.app bundle, used to pin the client's code signature
set -euo pipefail

PAYLOAD_DIR="${1:-}"
APP_BUNDLE="${2:-}"

LABEL="org.veil.app.helper"
INSTALL_DIR="/Library/Application Support/Veil/helper"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
REQUIREMENT_FILE="${INSTALL_DIR}/client.requirement"

log() { echo "[install-daemon] $*"; }

if [ "$(id -u)" != "0" ]; then
  log "ERROR: must run as root"; exit 1
fi
if [ -z "${PAYLOAD_DIR}" ] || [ ! -d "${PAYLOAD_DIR}" ]; then
  log "ERROR: payload directory not provided or missing"; exit 1
fi
if [ -z "${APP_BUNDLE}" ] || [ ! -d "${APP_BUNDLE}" ]; then
  log "ERROR: app bundle not provided or missing"; exit 1
fi
for f in VeilHelper sing-box; do
  [ -f "${PAYLOAD_DIR}/${f}" ] || { log "ERROR: missing ${f} in payload"; exit 1; }
done

# --- 1. Work out which client the helper is allowed to talk to -------------
# A Developer ID build is pinned by team; an ad-hoc build (what Veil ships,
# since there is no paid Apple membership) can only be pinned by the exact
# hash of the binary, so the helper has to be reinstalled after every update.
SIGN_INFO="$(codesign -d --verbose=4 "${APP_BUNDLE}" 2>&1 || true)"
IDENTIFIER="$(printf '%s\n' "${SIGN_INFO}" | awk -F= '/^Identifier=/{print $2; exit}')"
TEAM_ID="$(printf '%s\n' "${SIGN_INFO}" | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
CDHASH="$(printf '%s\n' "${SIGN_INFO}" | awk -F= '/^CDHash=/{print $2; exit}')"

if [ -z "${IDENTIFIER}" ]; then
  log "ERROR: ${APP_BUNDLE} is not signed at all; refusing to install"
  exit 1
fi

if [ -n "${TEAM_ID}" ] && [ "${TEAM_ID}" != "not set" ]; then
  REQUIREMENT="anchor apple generic and identifier \"${IDENTIFIER}\" and certificate leaf[subject.OU] = \"${TEAM_ID}\""
  log "pinning client by team ${TEAM_ID}"
elif [ -n "${CDHASH}" ]; then
  REQUIREMENT="identifier \"${IDENTIFIER}\" and cdhash H\"${CDHASH}\""
  log "pinning ad-hoc client by cdhash"
else
  log "ERROR: could not read a code signature from ${APP_BUNDLE}"
  exit 1
fi

# --- 2. Install the payload ------------------------------------------------
/bin/mkdir -p "${INSTALL_DIR}"
/usr/sbin/chown -R root:wheel "/Library/Application Support/Veil"
/bin/chmod 0755 "/Library/Application Support/Veil" "${INSTALL_DIR}"

/usr/bin/install -m 0755 -o root -g wheel "${PAYLOAD_DIR}/VeilHelper" "${INSTALL_DIR}/VeilHelper"
# The routing core the helper runs as root for the native TUN inbound.
/usr/bin/install -m 0755 -o root -g wheel "${PAYLOAD_DIR}/sing-box" "${INSTALL_DIR}/sing-box"
# tun2socks stays as the fallback transport for anyone who turns the native
# inbound off; it is optional, so a payload without it still installs.
if [ -f "${PAYLOAD_DIR}/tun2socks" ]; then
  /usr/bin/install -m 0755 -o root -g wheel "${PAYLOAD_DIR}/tun2socks" "${INSTALL_DIR}/tun2socks"
fi
# Working directory for the core's cache and downloaded rule-sets.
/bin/mkdir -p "${INSTALL_DIR}/core"
/usr/sbin/chown root:wheel "${INSTALL_DIR}/core"
/bin/chmod 0700 "${INSTALL_DIR}/core"
/usr/bin/xattr -dr com.apple.quarantine "${INSTALL_DIR}" 2>/dev/null || true

# World-readable but root-only writable: the helper refuses to start if anyone
# else can edit the requirement it authorises clients with.
printf '%s\n' "${REQUIREMENT}" > "${REQUIREMENT_FILE}"
/usr/sbin/chown root:wheel "${REQUIREMENT_FILE}"
/bin/chmod 0644 "${REQUIREMENT_FILE}"
log "installed payload to ${INSTALL_DIR}"

# --- 3. Install and load the LaunchDaemon ---------------------------------
cat > "${PLIST}" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${INSTALL_DIR}/VeilHelper</string>
  </array>
  <key>MachServices</key>
  <dict>
    <key>${LABEL}</key><true/>
  </dict>
  <key>RunAtLoad</key><false/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PLISTEOF
/usr/sbin/chown root:wheel "${PLIST}"
/bin/chmod 0644 "${PLIST}"

/bin/launchctl bootout "system/${LABEL}" 2>/dev/null || true
/bin/launchctl bootstrap system "${PLIST}"
log "loaded ${LABEL}"

# --- 4. Remove older installs ---------------------------------------------
# Before the app id became org.veil.app the helper ran under this label.
LEGACY_LABEL="dev.local.veil.helper"
/bin/launchctl bootout "system/${LEGACY_LABEL}" 2>/dev/null || true
if [ -f "/Library/LaunchDaemons/${LEGACY_LABEL}.plist" ]; then
  /bin/rm -f "/Library/LaunchDaemons/${LEGACY_LABEL}.plist"
  log "removed the legacy ${LEGACY_LABEL} daemon"
fi
if [ -f /etc/sudoers.d/xrayclient ]; then
  /bin/rm -f /etc/sudoers.d/xrayclient
  log "removed the legacy NOPASSWD sudoers rule"
fi
/bin/rm -rf /usr/local/libexec/xrayclient
/bin/rm -f /tmp/xrayclient-tun2socks.pid /tmp/xrayclient-tun.state \
           /tmp/xrayclient-tun.pinned /tmp/xrayclient-ping.pinned /tmp/tun2socks.log

log "Helper installed. TUN mode no longer needs a password."
