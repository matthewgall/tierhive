#!/bin/sh

# Exit immediately on error and treat unset variables as errors.
set -eu

LOG_PIPE="/tmp/netbird-runsh-log.$$"
LOG_PID=""

start_logging() {
    mkfifo "$LOG_PIPE"
    tee -a /root/netbird-install.log < "$LOG_PIPE" &
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

[ -f "$0" ] && cp "$0" /root/netbird-installScript.sh.txt

echo '######################################'
echo '#                                    #'
echo '#         Installing Netbird         #'
echo '#                                    #'
echo '######################################'

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

# Optional TierHive variable: netbird_version
DEFAULT_NETBIRD_VERSION="0.74.4"
netbird_version=${netbird_version:-$DEFAULT_NETBIRD_VERSION}

# Normalise version to include a leading 'v' internally.
case "$netbird_version" in
    v*) VERSION="$netbird_version" ;;
    *) VERSION="v$netbird_version" ;;
esac

case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    i?86|x86) ARCH=386 ;;
    *)
        echo "ERROR: Unsupported architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

BIN_PATH="/usr/bin/netbird"
DOWNLOAD_URL="https://github.com/netbirdio/netbird/releases/download/${VERSION}/netbird_${VERSION#v}_linux_${ARCH}.tar.gz"

if [ ! -c /dev/net/tun ]; then
    echo "TUN device not present; attempting to load the tun module..."
    if modprobe tun 2>/dev/null; then
        echo "Loaded tun module."
    fi
fi

if [ ! -c /dev/net/tun ]; then
    echo "ERROR: /dev/net/tun is not available." >&2
    echo "Netbird requires a TUN device. Please ask your hosting provider (TierHive) to enable TUN/TAP support, then re-run this script." >&2
    exit 1
fi

# Ensure tun loads on boot.
if [ ! -f /etc/modules-load.d/tun.conf ] || ! grep -qx "tun" /etc/modules-load.d/tun.conf; then
    echo "tun" > /etc/modules-load.d/tun.conf
    echo "Configured tun module to load on boot."
fi

# Netbird manages firewall rules using nftables.
if ! command -v nft >/dev/null 2>&1; then
    echo "Installing nftables..."
    apk add --no-cache nftables
fi

if ! lsmod 2>/dev/null | grep -q "^nf_tables"; then
    echo "Loading nf_tables module..."
    modprobe nf_tables 2>/dev/null || true
fi

if [ ! -f /etc/modules-load.d/nf_tables.conf ] || ! grep -qx "nf_tables" /etc/modules-load.d/nf_tables.conf; then
    echo "nf_tables" > /etc/modules-load.d/nf_tables.conf
    echo "Configured nf_tables module to load on boot."
fi

download() {
    url=$1
    dest=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$dest" "$url"
    else
        echo "ERROR: curl or wget is required to download Netbird." >&2
        exit 1
    fi
}

# Only download the binary if it is missing or not the requested version.
if [ -x "$BIN_PATH" ] && "$BIN_PATH" version 2>/dev/null | grep -q "${VERSION#v}"; then
    echo "Netbird ${VERSION} already installed at $BIN_PATH; skipping download."
else
    echo "Downloading Netbird ${VERSION} for linux-${ARCH}..."
    TMP_DIR="/tmp/netbird-install.$$"
    mkdir -p "$TMP_DIR"
    download "$DOWNLOAD_URL" "$TMP_DIR/netbird.tar.gz"
    tar -xzf "$TMP_DIR/netbird.tar.gz" -C "$TMP_DIR"
    chmod +x "$TMP_DIR/netbird"
    mv "$TMP_DIR/netbird" "$BIN_PATH"
    rm -rf "$TMP_DIR"
    echo "Installed Netbird at $BIN_PATH"
fi

"$BIN_PATH" version

echo "Installing Netbird service..."
if [ -f /etc/init.d/netbird ]; then
    echo "Netbird service already installed."
else
    HOME=/root "$BIN_PATH" service install
fi

if [ ! -L /etc/runlevels/default/netbird ]; then
    rc-update add netbird default
    echo "Netbird added to default runlevel."
else
    echo "Netbird already in default runlevel."
fi

cat > /root/netbird.info.txt << 'EOF'
Netbird has been installed and enabled.

To start the daemon and connect this machine:

    rc-service netbird start

Then log in with your setup key:

    HOME=/root netbird login --setup-key YOUR_SETUP_KEY
    HOME=/root netbird up

If you want Netbird to start automatically on boot (already enabled):

    rc-update add netbird default

Management URL: https://app.netbird.io
EOF

echo "Installation complete."
echo "See /root/netbird.info.txt for next steps."
