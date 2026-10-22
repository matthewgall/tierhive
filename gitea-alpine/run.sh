#!/bin/sh

# Exit immediately on error and treat unset variables as errors.
set -eu

LOG_PIPE="/tmp/gitea-runsh-log.$$"
LOG_PID=""

start_logging() {
    mkfifo "$LOG_PIPE"
    tee -a /root/gitea-install.log < "$LOG_PIPE" &
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

[ -f "$0" ] && cp "$0" /root/gitea-installScript.sh.txt

echo '######################################'
echo '#                                    #'
echo '#         Installing Gitea           #'
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
gitea_version=${gitea_version:-}
gitea_ssh_port=${gitea_ssh_port:-2222}
gitea_http_port=${gitea_http_port:-3000}
gitea_admin_user=${gitea_admin_user:-}
gitea_admin_password=${gitea_admin_password:-}
gitea_admin_email=${gitea_admin_email:-admin@example.com}
gitea_domain=${gitea_domain:-localhost}

if [ -z "$gitea_version" ]; then
    DEFAULT_GITEA_VERSION=$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/go-gitea/gitea/releases/latest 2>/dev/null | sed 's|.*/||')
    if [ -z "$DEFAULT_GITEA_VERSION" ]; then
        DEFAULT_GITEA_VERSION="v1.22.3"
    fi
    gitea_version=$DEFAULT_GITEA_VERSION
fi

case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    armv7l) ARCH=arm-7 ;;
    armv6l|armv8l|arm) ARCH=arm-6 ;;
    *)
        echo "ERROR: Unsupported architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

BIN_PATH="/usr/local/bin/gitea"
INSTALL_DIR="/var/lib/gitea"
CONF_DIR="/etc/gitea"
SVC_FILE="/etc/init.d/gitea"

version_no_v=$(echo "$gitea_version" | sed 's/^v//')
DOWNLOAD_URL="https://github.com/go-gitea/gitea/releases/download/${gitea_version}/gitea-${version_no_v}-linux-${ARCH}"

download() {
    url=$1
    dest=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$dest" "$url"
    else
        echo "ERROR: curl or wget is required to download Gitea." >&2
        exit 1
    fi
}

# Create git user if missing.
if ! id -u git >/dev/null 2>&1; then
    adduser -D -H -s /sbin/nologin -h "$INSTALL_DIR" git
fi

mkdir -p "$INSTALL_DIR" "$CONF_DIR" "$INSTALL_DIR"/custom "$INSTALL_DIR"/data "$INSTALL_DIR"/log

installed_version=""
if [ -x "$BIN_PATH" ]; then
    installed_version=$("$BIN_PATH" --version 2>/dev/null | sed -n 's/.*Gitea version \([^ ]*\).*/\1/p' | head -n 1)
fi

binary_updated=0
if [ "$installed_version" = "$version_no_v" ]; then
    echo "Gitea ${gitea_version} already installed at $BIN_PATH; skipping download."
else
    if [ -n "$installed_version" ]; then
        echo "Upgrading Gitea from ${installed_version} to ${gitea_version}..."
    else
        echo "Downloading Gitea ${gitea_version} for linux-${ARCH}..."
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
    echo "Installed Gitea at $BIN_PATH"
fi
"$BIN_PATH" --version

chown -R git:git "$INSTALL_DIR" "$CONF_DIR"
chmod 750 "$CONF_DIR"

# Minimal app.ini if it does not already exist.
if [ ! -f "$CONF_DIR/app.ini" ]; then
    cat > "$CONF_DIR/app.ini" << EOF
APP_NAME = Gitea: Git with a cup of tea
RUN_USER = git
RUN_MODE = prod

[repository]
ROOT = $INSTALL_DIR/data/gitea-repositories

[server]
PROTOCOL = http
DOMAIN = $gitea_domain
HTTP_PORT = $gitea_http_port
ROOT_URL = http://$gitea_domain:$gitea_http_port/
DISABLE_SSH = false
SSH_PORT = $gitea_ssh_port
SSH_LISTEN_PORT = $gitea_ssh_port
LFS_START_SERVER = true
LFS_CONTENT_PATH = $INSTALL_DIR/data/lfs

[database]
DB_TYPE = sqlite3
PATH = $INSTALL_DIR/data/gitea.db

[log]
MODE = file
LEVEL = Info
ROOT_PATH = $INSTALL_DIR/log

[security]
INSTALL_LOCK = true
EOF
    chown git:git "$CONF_DIR/app.ini"
    chmod 640 "$CONF_DIR/app.ini"
    echo "Created default config at $CONF_DIR/app.ini"
fi

echo "Installing OpenRC service..."
cat > "$SVC_FILE" << 'EOF'
#!/sbin/openrc-run

name="gitea"
description="Gitea: Git with a cup of tea"

command="/usr/local/bin/gitea"
command_args="web --config /etc/gitea/app.ini"
command_user="git:git"
command_background=true
pidfile="/run/gitea.pid"

directory="/var/lib/gitea"
export HOME=/var/lib/gitea
export GITEA_WORK_DIR=/var/lib/gitea

depend() {
    need net
    after firewall
}
EOF
chmod +x "$SVC_FILE"

if [ -L /etc/runlevels/default/gitea ]; then
    echo "gitea already in default runlevel."
else
    rc-update add gitea default
    echo "gitea added to default runlevel."
fi

echo "Ensuring no stale Gitea processes are running..."
rc-service gitea stop 2>/dev/null || true
pkill -x gitea 2>/dev/null || true
sleep 2

echo "Starting gitea..."
rc-service gitea start </dev/null 2>/dev/null || true

echo "Waiting for Gitea to be ready..."
ready=0
for i in 1 2 3 4 5 6 7 8 9 10; do
    if netstat -tln 2>/dev/null | grep -qE ":${gitea_http_port}[[:space:]]"; then
        ready=1
        break
    fi
    sleep 1
done

if [ "$ready" -eq 1 ]; then
    echo "Gitea is listening on port $gitea_http_port."
else
    echo "Warning: Gitea does not appear to be listening on port $gitea_http_port." >&2
    echo "Check $INSTALL_DIR/log for details." >&2
fi

# Create admin user if requested and Gitea is up.
if [ -n "$gitea_admin_user" ] && [ -n "$gitea_admin_password" ] && [ "$ready" -eq 1 ]; then
    echo "Creating admin user $gitea_admin_user..."
    su -s /bin/sh git -c "$BIN_PATH admin user create --admin --username $gitea_admin_user --password $gitea_admin_password --email $gitea_admin_email" 2>/dev/null || true
fi

cat > /root/gitea.info.txt << EOF
Gitea has been installed and enabled.

Web UI: http://$gitea_domain:$gitea_http_port
Git+SSH: ssh://git@$gitea_domain:$gitea_ssh_port
Config: $CONF_DIR/app.ini
Data:   $INSTALL_DIR/data
Logs:   $INSTALL_DIR/log

Default admin credentials:
  Username: $gitea_admin_user
  Password: (set from environment)

If no admin user was created, you can create one with:
    su -s /bin/sh git -c "$BIN_PATH admin user create --admin --username <user> --password <pass> --email <email>"
EOF

echo "Installation complete."
echo "See /root/gitea.info.txt for next steps."
