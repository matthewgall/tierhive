#!/bin/sh

# Exit immediately on error and treat unset variables as errors.
set -eu

LOG_PIPE="/tmp/rqlite-uninstall-log.$$"
LOG_PID=""

start_logging() {
    mkfifo "$LOG_PIPE"
    tee -a /root/rqlite-uninstall.log < "$LOG_PIPE" &
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
echo '#        Uninstalling rqlite         #'
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

echo "Stopping and disabling rqlite..."
rc-service rqlite stop 2>/dev/null || true
rc-update del rqlite default 2>/dev/null || true

for pid in $(pidof rqlited 2>/dev/null); do
    kill -9 "$pid" 2>/dev/null || true
done
sleep 1

echo "Removing files..."
rm -f /etc/init.d/rqlite
rm -f /etc/runlevels/default/rqlite
rm -f /usr/local/bin/rqlited
rm -f /usr/local/bin/rqlite
rm -f /usr/local/bin/rqbench

# Data and config are preserved by default.
# Uncomment the next two lines to remove them as well.
# rm -rf /etc/rqlite
# rm -rf /var/lib/rqlite

echo "rqlite uninstalled."
echo "Config in /etc/rqlite and data in /var/lib/rqlite were preserved."
