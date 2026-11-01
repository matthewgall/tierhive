#!/bin/sh

# Exit immediately on error and treat unset variables as errors.
set -eu

LOG_PIPE="/tmp/github-runner-runsh-log.$$"
LOG_PID=""

start_logging() {
    mkfifo "$LOG_PIPE"
    tee -a /root/github-runner-install.log < "$LOG_PIPE" &
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

[ -f "$0" ] && cp "$0" /root/github-runner-installScript.sh.txt

echo '######################################'
echo '#                                    #'
echo '#     Installing GitHub Actions runner'
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

# Required TierHive variables.
github_url=${github_url:-}
github_token=${github_token:-}

# Optional TierHive variables.
github_version=${github_version:-}
github_runner_name=${github_runner_name:-$(hostname)}
github_runner_group=${github_runner_group:-default}
github_labels=${github_labels:-}
github_runner_dir=${github_runner_dir:-/opt/actions-runner}
github_runner_user=${github_runner_user:-github-runner}

if [ -z "$github_url" ]; then
    echo "ERROR: github_url is required. Set it to the repository or organization URL." >&2
    exit 1
fi

if [ -z "$github_token" ]; then
    echo "ERROR: github_token is required. Get it from Settings > Actions > Runners > New runner." >&2
    exit 1
fi

case "$(uname -m)" in
    x86_64|amd64) ARCH=x64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    armv7l|armv6l|arm) ARCH=arm ;;
    *)
        echo "ERROR: Unsupported architecture: $(uname -m). GitHub runner supports x64, arm64, and arm." >&2
        exit 1
        ;;
esac

if [ -z "$github_version" ]; then
    DEFAULT_VERSION=$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/actions/runner/releases/latest 2>/dev/null | sed 's|.*/||')
    if [ -z "$DEFAULT_VERSION" ]; then
        DEFAULT_VERSION="v2.338.2"
    fi
    github_version=$DEFAULT_VERSION
fi

version_no_v=$(echo "$github_version" | sed 's/^v//')
TARBALL="actions-runner-linux-${ARCH}-${version_no_v}.tar.gz"
DOWNLOAD_URL="https://github.com/actions/runner/releases/download/${github_version}/${TARBALL}"

download() {
    url=$1
    dest=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$dest" "$url"
    else
        echo "ERROR: curl or wget is required to download the GitHub runner." >&2
        exit 1
    fi
}

# The official runner is built against glibc. gcompat provides glibc compatibility on musl.
echo "Installing dependencies..."
apk add --no-cache gcompat icu-libs curl git nodejs bash sudo

# Create runner user if missing.
if ! id -u "$github_runner_user" >/dev/null 2>&1; then
    adduser -D -H -s /bin/sh -h "$github_runner_dir" "$github_runner_user"
fi

mkdir -p "$github_runner_dir"

echo "Downloading GitHub Actions runner ${github_version} for linux-${ARCH}..."
TMP_FILE="/tmp/github-runner.tar.gz"
download "$DOWNLOAD_URL" "$TMP_FILE"

# Back up existing config if present.
if [ -f "$github_runner_dir/.runner" ]; then
    echo "Backing up existing runner configuration..."
    cp "$github_runner_dir/.runner" "$github_runner_dir/.runner.bak.$(date +%Y%m%d%H%M%S)"
fi

# Clear old files before extracting, preserving any _diag logs.
if [ -d "$github_runner_dir" ]; then
    find "$github_runner_dir" -mindepth 1 -maxdepth 1 ! -name '_diag' -exec rm -rf {} + 2>/dev/null || true
fi

mkdir -p "$github_runner_dir"
tar -xzf "$TMP_FILE" -C "$github_runner_dir"
rm -f "$TMP_FILE"
echo "Extracted to $github_runner_dir"

chown -R "$github_runner_user:$github_runner_user" "$github_runner_dir"
chmod 750 "$github_runner_dir"

# Add runner user to docker group if docker is installed.
if getent group docker >/dev/null 2>&1; then
    adduser "$github_runner_user" docker 2>/dev/null || true
fi

echo "Configuring runner..."
config_args="--url $github_url --token $github_token --name $github_runner_name --runnergroup $github_runner_group --unattended --replace"
if [ -n "$github_labels" ]; then
    config_args="$config_args --labels $github_labels"
fi

su -s /bin/sh "$github_runner_user" -c "cd $github_runner_dir && ./config.sh $config_args"

echo "Installing OpenRC service..."
SVC_FILE="/etc/init.d/github-runner"
cat > "$SVC_FILE" << EOF
#!/sbin/openrc-run

name="github-runner"
description="GitHub Actions self-hosted runner"

directory="$github_runner_dir"
command="$github_runner_dir/runsvc.sh"
command_user="$github_runner_user:$github_runner_user"

supervisor=supervise-daemon
respawn_delay=10
respawn_max=0

depend() {
    need net
    after firewall
}

start_pre() {
    if [ ! -f "$github_runner_dir/.service" ]; then
        eerror "Runner has not been configured. Run config.sh first."
        return 1
    fi
    chown -R $github_runner_user:$github_runner_user "$github_runner_dir"
}
EOF
chmod +x "$SVC_FILE"

if [ -L /etc/runlevels/default/github-runner ]; then
    echo "github-runner already in default runlevel."
else
    rc-update add github-runner default
    echo "github-runner added to default runlevel."
fi

echo "Ensuring no stale GitHub runner processes are running..."
rc-service github-runner stop 2>/dev/null || true
for pid in $(pidof Runner.Listener 2>/dev/null || pidof runsvc.sh 2>/dev/null); do
    kill -9 "$pid" 2>/dev/null || true
done
sleep 2

echo "Starting github-runner..."
rc-service github-runner start </dev/null 2>/dev/null || true

cat > /root/github-runner.info.txt << EOF
GitHub Actions runner has been installed and enabled.

Runner name: $github_runner_name
Directory:   $github_runner_dir
User:        $github_runner_user

Service commands:
    rc-service github-runner restart
    rc-service github-runner status
    tail -f /var/log/github-runner.log

To check runner logs:
    su -s /bin/sh $github_runner_user -c "tail -f $github_runner_dir/_diag/*.log"
EOF

echo "Installation complete."
echo "See /root/github-runner.info.txt for next steps."
