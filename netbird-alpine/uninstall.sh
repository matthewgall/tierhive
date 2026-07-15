#!/bin/sh

# Exit immediately on error and treat unset variables as errors.
set -eu

LOG_PIPE="/tmp/netbird-uninstall-log.$$"
LOG_PID=""

start_logging() {
    mkfifo "$LOG_PIPE"
    tee -a /root/netbird-uninstall.log < "$LOG_PIPE" &
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
echo '#        Uninstalling Netbird        #'
echo '#                                    #'
echo '######################################'

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

BIN_PATH="/usr/bin/netbird"

if [ -x "$BIN_PATH" ]; then
    echo "Stopping Netbird service..."
    HOME=/root "$BIN_PATH" service stop 2>/dev/null || true
    echo "Uninstalling Netbird service..."
    HOME=/root "$BIN_PATH" service uninstall 2>/dev/null || true
fi

rm -f "$BIN_PATH"
rm -rf /etc/netbird
rm -f /etc/init.d/netbird
rm -f /etc/runlevels/default/netbird

echo "Netbird uninstalled."
