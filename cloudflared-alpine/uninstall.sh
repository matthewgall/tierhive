#!/bin/sh

# Exit immediately on error and treat unset variables as errors.
set -eu

LOG_PIPE="/tmp/cloudflared-uninstall-log.$$"
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

# Optional TierHive variables: cloudflared_name, cloudflared_purge
cloudflared_name=${cloudflared_name:-cloudflared}
cloudflared_purge=${cloudflared_purge:-0}

SVC_FILE="/etc/init.d/${cloudflared_name}"
CONF_FILE="/etc/conf.d/${cloudflared_name}"
RUNLEVEL_LINK="/etc/runlevels/default/${cloudflared_name}"
BIN_PATH="/usr/local/bin/cloudflared"

echo "Uninstalling cloudflared instance '${cloudflared_name}'..."

if [ -f "$SVC_FILE" ] || [ -L "$RUNLEVEL_LINK" ]; then
    rc-service "$cloudflared_name" stop </dev/null 2>/dev/null || true
    rc-update del "$cloudflared_name" default </dev/null 2>/dev/null || true
    rm -f "$RUNLEVEL_LINK"
    rm -f "$SVC_FILE"
    echo "Removed service '${cloudflared_name}'."
else
    echo "Service '${cloudflared_name}' not found; nothing to stop or remove."
fi

if [ -f "$CONF_FILE" ]; then
    rm -f "$CONF_FILE"
    echo "Removed config $CONF_FILE."
fi

if [ "$cloudflared_purge" = "1" ]; then
    remaining=$(find /etc/init.d -maxdepth 1 -name 'cloudflared*' -type f 2>/dev/null | wc -l)
    if [ "$remaining" -gt 0 ]; then
        echo "Other cloudflared services still exist; skipping binary removal."
    else
        rm -f "$BIN_PATH"
        echo "Removed binary $BIN_PATH."
    fi
fi

echo "Uninstall complete."
