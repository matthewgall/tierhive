#!/bin/sh

# Exit immediately on error and treat unset variables as errors.
set -eu

LOG_PIPE="/tmp/cloudflared-debian-uninstall-log.$$"
LOG_PID=""

start_logging() {
    mkfifo "$LOG_PIPE"
    tee -a /root/cloudflared-uninstall.log < "$LOG_PIPE" &
    LOG_PID=$!
    exec > "$LOG_PIPE" 2>&1
}

cleanup() {
    rc=$1
    set +e
    if [ "$rc" -ne 0 ]; then
        echo "ERROR: Uninstall failed with exit code $rc" >&2
    fi
    exec >/dev/null 2>&1
    if [ -n "$LOG_PID" ]; then
        kill "$LOG_PID" 2>/dev/null
    fi
    rm -f "$LOG_PIPE"
}

start_logging
trap 'cleanup $?' EXIT

echo '######################################'
echo '#                                    #'
echo '#      Uninstalling cloudflared      #'
echo '#                                    #'
echo '######################################'

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

if [ ! -d /run/systemd/system ] && [ ! -x /bin/systemctl ] && [ ! -x /usr/bin/systemctl ]; then
    echo "ERROR: This script is designed for Debian/Ubuntu with systemd." >&2
    exit 1
fi

cloudflared_name=${cloudflared_name:-cloudflared}

BIN_PATH="/usr/local/bin/cloudflared"
CONF_FILE="/etc/default/${cloudflared_name}"
SERVICE_FILE="/etc/systemd/system/${cloudflared_name}.service"
LOG_FILE="/var/log/${cloudflared_name}.log"

echo "Stopping and disabling '${cloudflared_name}' service..."
systemctl stop "${cloudflared_name}.service" 2>/dev/null || true
systemctl disable "${cloudflared_name}.service" 2>/dev/null || true

echo "Removing '${cloudflared_name}' files..."
rm -f "$SERVICE_FILE"
rm -f "$CONF_FILE"
rm -f "$LOG_FILE"

# Only remove the shared binary if no other cloudflared services remain.
remaining=$(find /etc/systemd/system -maxdepth 1 -name 'cloudflared*.service' -type f 2>/dev/null | wc -l)
if [ "$remaining" -eq 0 ]; then
    rm -f "$BIN_PATH"
    echo "Removed shared binary $BIN_PATH."
else
    echo "Other cloudflared services still exist; skipping shared binary removal."
fi

systemctl daemon-reload

echo "'${cloudflared_name}' uninstalled."
