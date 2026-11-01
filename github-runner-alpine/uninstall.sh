#!/bin/sh

# Exit immediately on error and treat unset variables as errors.
set -eu

LOG_PIPE="/tmp/github-runner-uninstall-log.$$"
LOG_PID=""

start_logging() {
    mkfifo "$LOG_PIPE"
    tee -a /root/github-runner-uninstall.log < "$LOG_PIPE" &
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
echo '#   Uninstalling GitHub Actions runner'
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

RUNNER_DIR="/opt/actions-runner"
RUNNER_USER="${github_runner_user:-github-runner}"

echo "Stopping and disabling github-runner..."
rc-service github-runner stop 2>/dev/null || true
rc-update del github-runner default 2>/dev/null || true

for pid in $(pidof Runner.Listener 2>/dev/null); do
    kill -9 "$pid" 2>/dev/null || true
done
for pid in $(pidof runsvc.sh 2>/dev/null); do
    kill -9 "$pid" 2>/dev/null || true
done
sleep 1

echo "Removing files..."
rm -f /etc/init.d/github-runner
rm -f /etc/runlevels/default/github-runner
rm -rf "$RUNNER_DIR"

echo "GitHub Actions runner uninstalled."
echo "Note: the runner may still appear in the GitHub UI until removed there."
