#!/bin/sh

# Exit immediately on error and treat unset variables as errors.
set -eu

LOG_PIPE="/tmp/technitium-dns-uninstall-log.$$"
LOG_PID=""

start_logging() {
    mkfifo "$LOG_PIPE"
    tee -a /root/technitium-dns-uninstall.log < "$LOG_PIPE" &
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
echo '#   Uninstalling Technitium DNS Server'
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

rc-service technitium-dns stop 2>/dev/null || true
rc-update del technitium-dns default 2>/dev/null || true

rm -f /etc/runlevels/default/technitium-dns
rm -f /etc/init.d/technitium-dns
rm -rf /opt/technitium/dns
rm -f /var/log/technitium-dns.log

echo "Technitium DNS Server uninstalled."
echo "Config in /etc/dns was preserved. Remove it manually if no longer needed."
