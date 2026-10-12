#!/bin/sh

# Exit immediately on error and treat unset variables as errors.
set -eu

LOG_PIPE="/tmp/cloudflared-debian-runsh-log.$$"
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

if [ ! -d /run/systemd/system ] && [ ! -x /bin/systemctl ] && [ ! -x /usr/bin/systemctl ]; then
    echo "ERROR: This script is designed for Debian/Ubuntu with systemd." >&2
    exit 1
fi

# Optional TierHive variables: cloudflared_name, cloudflared_version, cloudflare_token
cloudflared_name=${cloudflared_name:-cloudflared}
if [ -z "${cloudflared_version:-}" ]; then
    DEFAULT_CLOUDFLARED_VERSION=$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/cloudflare/cloudflared/releases/latest 2>/dev/null | sed 's|.*/||')
    if [ -z "$DEFAULT_CLOUDFLARED_VERSION" ]; then
        DEFAULT_CLOUDFLARED_VERSION="2026.10.0"
    fi
    cloudflared_version=$DEFAULT_CLOUDFLARED_VERSION
fi
token_value=${cloudflare_token:-}

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

BIN_PATH="/usr/local/bin/cloudflared"
CONF_FILE="/etc/default/${cloudflared_name}"
SERVICE_FILE="/etc/systemd/system/${cloudflared_name}.service"
LOG_FILE="/var/log/${cloudflared_name}.log"
DOWNLOAD_URL="https://github.com/cloudflare/cloudflared/releases/download/${cloudflared_version}/cloudflared-linux-${ARCH}"

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

# Only download the binary if it is missing or not the requested version.
installed_version=""
if [ -x "$BIN_PATH" ]; then
    installed_version=$("$BIN_PATH" --version 2>/dev/null | sed -n 's/.* \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1)
fi

binary_updated=0
if [ "$installed_version" = "$cloudflared_version" ]; then
    echo "cloudflared ${cloudflared_version} already installed at $BIN_PATH; skipping download."
else
    if [ -n "$installed_version" ]; then
        echo "Upgrading cloudflared from ${installed_version} to ${cloudflared_version}..."
    else
        echo "Downloading cloudflared ${cloudflared_version} for linux-${ARCH}..."
    fi
    TMP_PATH="${BIN_PATH}.tmp"
    download "$DOWNLOAD_URL" "$TMP_PATH"
    chmod +x "$TMP_PATH"

    if ! "$TMP_PATH" --version >/dev/null 2>&1; then
        echo "ERROR: Downloaded binary does not execute." >&2
        rm -f "$TMP_PATH"
        exit 1
    fi

    mv "$TMP_PATH" "$BIN_PATH"
    binary_updated=1
    echo "Installed cloudflared at $BIN_PATH"
fi
"$BIN_PATH" --version

echo "Installing systemd service '${cloudflared_name}'..."
cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Cloudflare Tunnel (${cloudflared_name})
After=network.target

[Service]
Type=simple
Environment="HOME=/root"
EnvironmentFile=-${CONF_FILE}
ExecStart=${BIN_PATH} tunnel --no-autoupdate run --token \$TOKEN
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOF

if [ ! -f "$CONF_FILE" ]; then
    cat > "$CONF_FILE" << 'EOF'
# Cloudflare Tunnel token for this instance.
# Get your token from the Cloudflare Zero Trust dashboard:
# https://one.dash.cloudflare.com/
TOKEN=""
EOF
    echo "Created default config at $CONF_FILE"
fi

if [ -n "$token_value" ]; then
    sed -i "s/^TOKEN=.*/TOKEN=\"$token_value\"/" "$CONF_FILE"
    echo "Set token for '${cloudflared_name}' from environment."
fi

systemctl daemon-reload

if systemctl is-enabled --quiet "${cloudflared_name}.service" 2>/dev/null; then
    echo "'${cloudflared_name}' service already enabled."
else
    systemctl enable "${cloudflared_name}.service"
    echo "'${cloudflared_name}' added to default target."
fi

if [ -n "$token_value" ]; then
    echo "Starting '${cloudflared_name}'..."
    timeout 30 systemctl restart "${cloudflared_name}.service" || true
elif [ "$binary_updated" -eq 1 ] && systemctl is-active --quiet "${cloudflared_name}.service" 2>/dev/null; then
    echo "Restarting '${cloudflared_name}' to apply the updated binary..."
    timeout 30 systemctl restart "${cloudflared_name}.service" || true
fi

echo "Installation complete."
if [ -z "$token_value" ]; then
    echo "Set your token in $CONF_FILE, then run: systemctl restart ${cloudflared_name}"
fi
