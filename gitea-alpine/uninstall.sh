#!/bin/sh

# Exit immediately on error and treat unset variables as errors.
set -eu

LOG_PIPE="/tmp/gitea-uninstall-log.$$"
LOG_PID=""

start_logging() {
    mkfifo "$LOG_PIPE"
    tee -a /root/gitea-uninstall.log < "$LOG_PIPE" &
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
echo '#        Uninstalling Gitea          #'
echo '#                                    #'
echo '######################################'

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

if [ ! -x /sbin/openrc-run ] || [ ! -d /etc/init.d ]; then
    echo "ERROR: This script is designed for Alpine Linux with OpenRC." >&2
    exit 1
fi

echo "Stopping and disabling gitea..."
rc-service gitea stop 2>/dev/null || true
rc-update del gitea default 2>/dev/null || true

echo "Removing files..."
rm -f /etc/init.d/gitea
rm -f /etc/runlevels/default/gitea
rm -f /usr/local/bin/gitea

# Config and data are preserved by default.
# Remove the next two lines only if you also want to delete repos and config.
# rm -rf /etc/gitea
# rm -rf /var/lib/gitea

echo "Gitea uninstalled."
echo "Config in /etc/gitea and repositories in /var/lib/gitea were preserved."
