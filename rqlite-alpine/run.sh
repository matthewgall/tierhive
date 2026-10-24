#!/bin/sh

# Exit immediately on error and treat unset variables as errors.
set -eu

LOG_PIPE="/tmp/rqlite-runsh-log.$$"
LOG_PID=""

start_logging() {
    mkfifo "$LOG_PIPE"
    tee -a /root/rqlite-install.log < "$LOG_PIPE" &
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

[ -f "$0" ] && cp "$0" /root/rqlite-installScript.sh.txt

echo '######################################'
echo '#                                    #'
echo '#         Installing rqlite          #'
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

# Optional TierHive variables.
rqlite_version=${rqlite_version:-}
rqlite_http_port=${rqlite_http_port:-4001}
rqlite_raft_port=${rqlite_raft_port:-4002}
rqlite_data_dir=${rqlite_data_dir:-/var/lib/rqlite}

if [ -z "$rqlite_version" ]; then
    DEFAULT_RQLITE_VERSION=$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/rqlite/rqlite/releases/latest 2>/dev/null | sed 's|.*/||')
    if [ -z "$DEFAULT_RQLITE_VERSION" ]; then
        DEFAULT_RQLITE_VERSION="v10.6.4"
    fi
    rqlite_version=$DEFAULT_RQLITE_VERSION
fi

case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    armv7l|armv8l) ARCH=arm ;;
    armv6l) ARCH=arm-softfloat ;;
    arm) ARCH=arm ;;
    *)
        echo "ERROR: Unsupported architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

BIN_DIR="/usr/local/bin"
DATA_DIR="$rqlite_data_dir"
CONF_DIR="/etc/rqlite"
SVC_FILE="/etc/init.d/rqlite"

version_no_v=$(echo "$rqlite_version" | sed 's/^v//')
TARBALL="rqlite-${rqlite_version}-linux-${ARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/rqlite/rqlite/releases/download/${rqlite_version}/${TARBALL}"

# For amd64, prefer the musl build on Alpine.
if [ "$ARCH" = "amd64" ]; then
    TARBALL="rqlite-${rqlite_version}-linux-amd64-musl.tar.gz"
    DOWNLOAD_URL="https://github.com/rqlite/rqlite/releases/download/${rqlite_version}/${TARBALL}"
fi

download() {
    url=$1
    dest=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$dest" "$url"
    else
        echo "ERROR: curl or wget is required to download rqlite." >&2
        exit 1
    fi
}

# Create rqlite user if missing.
if ! id -u rqlite >/dev/null 2>&1; then
    adduser -D -H -s /sbin/nologin -h "$DATA_DIR" rqlite
fi

mkdir -p "$DATA_DIR" "$CONF_DIR"

echo "Downloading rqlite ${rqlite_version} for linux-${ARCH}..."
TMP_DIR="/tmp/rqlite-install.$$"
mkdir -p "$TMP_DIR"
download "$DOWNLOAD_URL" "$TMP_DIR/rqlite.tar.gz"
tar -xzf "$TMP_DIR/rqlite.tar.gz" -C "$TMP_DIR"

for binary in rqlited rqlite rqbench; do
    if [ -f "$TMP_DIR/$binary" ]; then
        mv "$TMP_DIR/$binary" "$BIN_DIR/$binary"
        chmod +x "$BIN_DIR/$binary"
        echo "Installed $binary to $BIN_DIR/$binary"
    fi
done

rm -rf "$TMP_DIR"

$BIN_DIR/rqlited --version

chown -R rqlite:rqlite "$DATA_DIR" "$CONF_DIR"
chmod 750 "$DATA_DIR"

echo "Installing OpenRC service..."
cat > "$SVC_FILE" << EOF
#!/sbin/openrc-run

name="rqlite"
description="rqlite: lightweight distributed SQL database"

command="$BIN_DIR/rqlited"
command_args="-http-addr 0.0.0.0:$rqlite_http_port -raft-addr 0.0.0.0:$rqlite_raft_port $DATA_DIR"
command_user="rqlite:rqlite"
command_background=true
pidfile="/run/rqlite.pid"

directory="$DATA_DIR"
export HOME=$DATA_DIR

depend() {
    need net
    after firewall
}
EOF
chmod +x "$SVC_FILE"

if [ -L /etc/runlevels/default/rqlite ]; then
    echo "rqlite already in default runlevel."
else
    rc-update add rqlite default
    echo "rqlite added to default runlevel."
fi

echo "Ensuring no stale rqlite processes are running..."
rc-service rqlite stop 2>/dev/null || true
pkill -x rqlited 2>/dev/null || true
sleep 2

echo "Starting rqlite..."
rc-service rqlite start </dev/null 2>/dev/null || true

echo "Waiting for rqlite to be ready..."
ready=0
for i in 1 2 3 4 5 6 7 8 9 10; do
    if netstat -tln 2>/dev/null | grep -qE ":${rqlite_http_port}[[:space:]]"; then
        ready=1
        break
    fi
    sleep 1
done

if [ "$ready" -eq 1 ]; then
    echo "rqlite is listening on port $rqlite_http_port."
else
    echo "Warning: rqlite does not appear to be listening on port $rqlite_http_port." >&2
fi

cat > /root/rqlite.info.txt << EOF
rqlite has been installed and enabled.

HTTP API: http://0.0.0.0:$rqlite_http_port
Raft:     0.0.0.0:$rqlite_raft_port
Data:     $DATA_DIR
Config:   $CONF_DIR

Example queries:
    curl -XPOST 'http://localhost:$rqlite_http_port/db/execute' \
      -H 'Content-Type: application/json' \
      -d '["CREATE TABLE foo (id INTEGER PRIMARY KEY, name TEXT)"]'

    curl -XPOST 'http://localhost:$rqlite_http_port/db/query' \
      -H 'Content-Type: application/json' \
      -d '["SELECT * FROM foo"]'
EOF

echo "Installation complete."
echo "See /root/rqlite.info.txt for next steps."
