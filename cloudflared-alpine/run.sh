#!/bin/sh

# Exit immediately on error and treat unset variables as errors.
set -eu

LOG_PIPE="/tmp/cloudflared-runsh-log.$$"
LOG_PID=""

start_logging() {
    mkfifo "$LOG_PIPE"
    tee -a /root/cloudflared-install.log < "$LOG_PIPE" &
    LOG_PID=$!
    exec > "$LOG_PIPE" 2>&1
}

cleanup() {
    rc=$1
    set +e
    if [ "$rc" -ne 0 ]; then
        echo "ERROR: Recipe failed with exit code $rc" >&2
    fi
    exec >/dev/null 2>&1
    if [ -n "$LOG_PID" ]; then
        kill "$LOG_PID" 2>/dev/null
    fi
    rm -f "$LOG_PIPE"
}

start_logging
trap 'cleanup $?' EXIT

[ -f "$0" ] && cp "$0" /root/cloudflared-installScript.sh.txt

echo '######################################'
echo '#                                    #'
echo '#       Installing cloudflared       #'
echo '#                                    #'
echo '######################################'

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

# Optional TierHive variables: cloudflared_name, cloudflared_version, cloudflare_token
DEFAULT_CLOUDFLARED_VERSION="2026.7.2"
cloudflared_name=${cloudflared_name:-cloudflared}
cloudflared_version=${cloudflared_version:-$DEFAULT_CLOUDFLARED_VERSION}
token_value=${cloudflare_token:-}

SVC_FILE="/etc/init.d/${cloudflared_name}"
CONF_FILE="/etc/conf.d/${cloudflared_name}"
RUNLEVEL_LINK="/etc/runlevels/default/${cloudflared_name}"

download() {
    url=$1
    dest=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$dest" "$url"
    else
        echo "ERROR: curl or wget is required to download cloudflared." >&2
        exit 1
    fi
}

case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    armv7l|armv6l|armv8l|arm) ARCH=armhf ;;
    armv5*|armv4*)
        ARCH=arm
        ;;
    *)
        echo "ERROR: Unsupported architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

BIN_DIR="/usr/local/bin"
BIN_PATH="${BIN_DIR}/cloudflared"
DOWNLOAD_URL="https://github.com/cloudflare/cloudflared/releases/download/${cloudflared_version}/cloudflared-linux-${ARCH}"

# Only download the binary if it is missing or not the requested version.
if [ -x "$BIN_PATH" ] && "$BIN_PATH" --version 2>/dev/null | grep -q "$cloudflared_version"; then
    echo "cloudflared ${cloudflared_version} already installed at $BIN_PATH; skipping download."
else
    echo "Downloading cloudflared ${cloudflared_version} for linux-${ARCH}..."
    TMP_PATH="${BIN_PATH}.tmp"
    download "$DOWNLOAD_URL" "$TMP_PATH"
    chmod +x "$TMP_PATH"

    if ! "$TMP_PATH" --version >/dev/null 2>&1; then
        echo "ERROR: Downloaded binary does not execute." >&2
        rm -f "$TMP_PATH"
        exit 1
    fi

    mv "$TMP_PATH" "$BIN_PATH"
    echo "Installed cloudflared at $BIN_PATH"
fi
"$BIN_PATH" --version

echo "Installing OpenRC service '${cloudflared_name}'..."
cat > "$SVC_FILE" << 'EOF'
#!/sbin/openrc-run

name="${RC_SVCNAME}"
description="Cloudflare Tunnel (${RC_SVCNAME})"
command="/usr/local/bin/cloudflared"
command_args="tunnel --no-autoupdate run --token ${token}"
command_user="root"
supervisor=supervise-daemon
pidfile="/run/${RC_SVCNAME}.pid"

depend() {
    need net
    after firewall
}

start_pre() {
    if [ -z "${token:-}" ]; then
        eerror "token is not set in /etc/conf.d/${RC_SVCNAME}"
        return 1
    fi
}
EOF
chmod +x "$SVC_FILE"

if [ ! -f "$CONF_FILE" ]; then
    cat > "$CONF_FILE" << 'EOF'
# Cloudflare Tunnel token for this instance.
# Get your token from the Cloudflare Zero Trust dashboard:
# https://one.dash.cloudflare.com/
token=""
EOF
    echo "Created default config at $CONF_FILE"
fi

if [ -n "$token_value" ]; then
    sed -i "s/^token=.*/token=\"$token_value\"/" "$CONF_FILE"
    echo "Set token for '${cloudflared_name}' from environment."
fi

if [ -L "$RUNLEVEL_LINK" ]; then
    echo "'${cloudflared_name}' already in default runlevel."
else
    rc-update add "$cloudflared_name" default
    echo "'${cloudflared_name}' added to default runlevel."
fi

if [ -n "$token_value" ]; then
    echo "Starting '${cloudflared_name}'..."
    rc-service "$cloudflared_name" restart 2>/dev/null || true
fi

echo "Installation complete."
if [ -z "$token_value" ]; then
    echo "Set your token in $CONF_FILE, then run: rc-service ${cloudflared_name} start"
fi
