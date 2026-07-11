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

# Optional TierHive variables: cloudflared_version, cloudflare_token
DEFAULT_CLOUDFLARED_VERSION="2026.7.1"
cloudflared_version=${cloudflared_version:-$DEFAULT_CLOUDFLARED_VERSION}
token_value=${cloudflare_token:-}

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
"$BIN_PATH" --version

echo "Installing OpenRC service..."
cat > /etc/init.d/cloudflared << 'EOF'
#!/sbin/openrc-run

name="cloudflared"
description="Cloudflare Tunnel"
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
        eerror "token is not set in /etc/conf.d/cloudflared"
        return 1
    fi
}
EOF
chmod +x /etc/init.d/cloudflared

if [ ! -f /etc/conf.d/cloudflared ]; then
    cat > /etc/conf.d/cloudflared << 'EOF'
# Cloudflare Tunnel token.
# Get your token from the Cloudflare Zero Trust dashboard:
# https://one.dash.cloudflare.com/
token=""
EOF
    echo "Created default config at /etc/conf.d/cloudflared"
fi

if [ -n "$token_value" ]; then
    sed -i "s/^token=.*/token=\"$token_value\"/" /etc/conf.d/cloudflared
    echo "Set cloudflared token from environment."
fi

if [ -L /etc/runlevels/default/cloudflared ]; then
    echo "cloudflared already in default runlevel."
else
    rc-update add cloudflared default
    echo "cloudflared added to default runlevel."
fi

if [ -n "$token_value" ]; then
    echo "Starting cloudflared..."
    rc-service cloudflared restart 2>/dev/null || true
fi

echo "Installation complete."
if [ -z "$token_value" ]; then
    echo "Set your token in /etc/conf.d/cloudflared, then run: rc-service cloudflared start"
fi
