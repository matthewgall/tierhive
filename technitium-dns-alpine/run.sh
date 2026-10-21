#!/bin/sh

# Exit immediately on error and treat unset variables as errors.
set -eu

LOG_PIPE="/tmp/technitium-dns-runsh-log.$$"
LOG_PID=""

start_logging() {
    mkfifo "$LOG_PIPE"
    tee -a /root/technitium-dns-install.log < "$LOG_PIPE" &
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

[ -f "$0" ] && cp "$0" /root/technitium-dns-installScript.sh.txt

echo '######################################'
echo '#                                    #'
echo '#    Installing Technitium DNS Server'
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
TECHNITIUM_URL=${technitium_url:-https://download.technitium.com/dns/DnsServerPortable.tar.gz}

# The .NET 10 runtime and libcap (for binding privileged ports) are required.
echo "Installing dependencies..."
apk add --no-cache aspnetcore10-runtime libcap

# Create a dedicated user/group if it does not already exist.
if ! id -u dns-server >/dev/null 2>&1; then
    adduser -D -H -s /sbin/nologin dns-server
fi

INSTALL_DIR="/opt/technitium/dns"
CONF_DIR="/etc/dns"
SVC_FILE="/etc/init.d/technitium-dns"

echo "Downloading Technitium DNS Server portable build..."
TMP_DIR="/tmp/technitium-dns-install.$$"
mkdir -p "$TMP_DIR"

if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$TMP_DIR/dns.tar.gz" "$TECHNITIUM_URL"
elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$TMP_DIR/dns.tar.gz" "$TECHNITIUM_URL"
else
    echo "ERROR: curl or wget is required." >&2
    exit 1
fi

echo "Extracting to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
tar -xzf "$TMP_DIR/dns.tar.gz" -C "$INSTALL_DIR"
rm -rf "$TMP_DIR"

mkdir -p "$CONF_DIR"
chown -R dns-server:dns-server "$INSTALL_DIR" "$CONF_DIR"
chmod 750 "$CONF_DIR"

mkdir -p /var/log/technitium/dns
chown -R dns-server:dns-server /var/log/technitium /etc/dns

echo "Granting dotnet the capability to bind privileged ports..."
setcap cap_net_bind_service=+ep /usr/lib/dotnet/dotnet

echo "Installing OpenRC service..."
cat > "$SVC_FILE" << 'EOF'
#!/sbin/openrc-run

description="Technitium DNS Server"

directory=/opt/technitium/dns

command="/usr/bin/dotnet"
command_args="/opt/technitium/dns/DnsServerApp.dll /etc/dns"
command_user=dns-server:dns-server
command_background=true
pidfile="/run/technitium-dns.pid"

depend() {
    need net
}

start_pre() {
    mkdir -p /var/log/technitium/dns
    chown -R dns-server:dns-server /var/log/technitium /etc/dns
}
EOF
chmod +x "$SVC_FILE"

if [ -L /etc/runlevels/default/technitium-dns ]; then
    echo "technitium-dns already in default runlevel."
else
    rc-update add technitium-dns default
    echo "technitium-dns added to default runlevel."
fi

echo "Ensuring no stale Technitium DNS Server processes are running..."
rc-service technitium-dns stop 2>/dev/null || true
pkill -x dotnet 2>/dev/null || true
sleep 2

echo "Starting technitium-dns..."
rc-service technitium-dns start </dev/null 2>/dev/null || true

# Verify the service is actually listening before declaring success.
echo "Waiting for Technitium DNS Server to be ready..."
ready=0
for i in 1 2 3 4 5 6 7 8 9 10; do
    if netstat -tln 2>/dev/null | grep -qE ":5380"; then
        ready=1
        break
    fi
    sleep 1
done

if [ "$ready" -eq 1 ]; then
    echo "Technitium DNS Server is listening on port 5380."
else
    echo "Warning: Technitium DNS Server does not appear to be listening on port 5380." >&2
    echo "Check /var/log/technitium/dns/ for details." >&2
fi

cat > /root/technitium-dns.info.txt << 'EOF'
Technitium DNS Server has been installed and enabled.

Web UI: http://<this-host>:5380
Default admin credentials: admin / admin

Important:
- This recipe requires IPv6 support. If you ran optimised-alpine/run.sh,
  make sure you used disable_ipv6=0.
- DNS ports 53/tcp and 53/udp must be reachable.
- Config is stored in /etc/dns.

Service commands:
    rc-service technitium-dns restart
    rc-service technitium-dns status
    tail -f /var/log/technitium/dns/*.log
EOF

echo "Installation complete."
echo "See /root/technitium-dns.info.txt for next steps."
