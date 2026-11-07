#!/bin/bash
# uninstall-daemon.sh — removes the Veil privileged helper and every trace of
# the older sudoers-based install. Run as root (one admin prompt).
set -uo pipefail

LABEL="org.veil.app.helper"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
INSTALL_DIR="/Library/Application Support/Veil/helper"

log() { echo "[uninstall-daemon] $*"; }

if [ "$(id -u)" != "0" ]; then
  log "ERROR: must run as root"; exit 1
fi

# Ask the helper's own teardown to run before the daemon goes away: booting it
# out with a tunnel up would leave the machine without a default route.
if /bin/launchctl print "system/${LABEL}" >/dev/null 2>&1; then
  /bin/launchctl bootout "system/${LABEL}" 2>/dev/null || true
  log "unloaded ${LABEL}"
fi

# The routing core runs as a child of the helper. Unloading the job should take
# it with it, but a core that outlived its parent would keep owning the default
# route, so make sure.
/usr/bin/pkill -f "${INSTALL_DIR}/sing-box" 2>/dev/null || true

# Whatever state was left behind, put the routes back by hand.
/sbin/route -n delete -net 0.0.0.0/1 >/dev/null 2>&1 || true
/sbin/route -n delete -net 128.0.0.0/1 >/dev/null 2>&1 || true

/bin/rm -f "${PLIST}"
/bin/rm -rf "${INSTALL_DIR}"
/bin/rmdir "/Library/Application Support/Veil" 2>/dev/null || true

# Legacy installs: the helper's label before the app id became org.veil.app,
# then the sudoers-based install.
/bin/launchctl bootout "system/dev.local.veil.helper" 2>/dev/null || true
/bin/rm -f /Library/LaunchDaemons/dev.local.veil.helper.plist
/bin/rm -f /etc/sudoers.d/xrayclient
/bin/rm -rf /usr/local/libexec/xrayclient
/bin/rm -f /tmp/xrayclient-tun2socks.pid /tmp/xrayclient-tun.state \
           /tmp/xrayclient-tun.pinned /tmp/xrayclient-ping.pinned /tmp/tun2socks.log

log "Helper removed."
