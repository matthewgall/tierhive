# TierHive Recipes

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)

A collection of Alpine Linux installation and optimisation recipes for use with [TierHive](https://tierhive.com/) and other VPS automation workflows. Each recipe is a self-contained POSIX `sh` script that can be fetched via `curl` and executed directly, or embedded into a provisioning pipeline.

All scripts are written for **Alpine Linux** and assume they are run as **root**.

## Repository Layout

```
tierhive/
├── optimised-alpine/
│   └── run.sh           # Harden and optimise Alpine 3.24.x for low-RAM headless servers
├── cloudflared-alpine/
│   ├── run.sh           # Install cloudflared with an OpenRC service
│   └── uninstall.sh     # Remove a cloudflared instance
├── cloudflared-debian/
│   ├── run.sh           # Install cloudflared with a systemd service
│   └── uninstall.sh     # Remove cloudflared
├── netbird-alpine/
│   ├── run.sh           # Install Netbird VPN/mesh agent
│   └── uninstall.sh     # Remove Netbird
├── technitium-dns-alpine/
│   ├── run.sh           # Install Technitium DNS Server
│   └── uninstall.sh     # Remove Technitium DNS Server
├── gitea-alpine/
│   ├── run.sh           # Install Gitea Git server
│   └── uninstall.sh     # Remove Gitea
├── rqlite-alpine/
│   ├── run.sh           # Install rqlite distributed SQL database
│   └── uninstall.sh     # Remove rqlite
└── README.md
```

## `optimised-alpine/run.sh`

Optimises Alpine 3.24.x for low-RAM, headless VPS workloads by:

- Blacklisting unnecessary kernel modules (graphics, HID, USB, KVM, legacy devices, cloud-specific NICs).
- Stripping the initramfs feature set to `base ext4 virtio`.
- Adding kernel command-line options: `ipv6.disable=1 audit=0 nowatchdog zswap.enabled=1`.
- Applying low-RAM sysctl tuning (socket buffers, cache pressure, pid max, watchdog disable, swappiness).
- Creating and enabling a swap file.
- Replacing `chronyd` with `ntpd`.
- Enabling `zswap` and reducing the bootloader timeout.

The script is idempotent and safe to run multiple times.

### Variables

| Variable | Default | Description |
|---|---|---|
| `swap_size` | *(required)* | Swap file size in MiB. |
| `disable_ipv6` | `1` | Set to `0` to keep IPv6 enabled (required for some services, e.g., Technitium DNS Server). |

### Usage

#### Via curl

```bash
# Standard low-RAM optimisation (IPv6 disabled)
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/optimised-alpine/run.sh | swap_size=512 sh

# Keep IPv6 support enabled
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/optimised-alpine/run.sh | disable_ipv6=0 swap_size=512 sh
```

#### From file

```bash
chmod +x optimised-alpine/run.sh
disable_ipv6=0 swap_size=512 ./optimised-alpine/run.sh
```

### Notes

- The script is POSIX `sh` compatible and does not require Bash.
- Progress is logged to `/root/recipe.log` and mirrored to stdout.
- A swap file is created early so memory-heavy steps such as `mkinitfs` have backing swap.
- Set `disable_ipv6=0` before installing any service that requires IPv6 (e.g., Technitium DNS Server).

## `cloudflared-alpine/run.sh`

Installs [cloudflared](https://github.com/cloudflare/cloudflared) on Alpine Linux and configures it as an OpenRC service using `supervise-daemon`. Supports multiple independent tunnel instances by giving each one a unique name.

### Variables

| Variable | Default | Description |
|---|---|---|
| `cloudflared_name` | `cloudflared` | Name of this tunnel instance. Each unique name gets its own OpenRC service and config file. |
| `cloudflared_version` | latest GitHub release | cloudflared release version to install. |
| `cloudflare_token` | *(optional)* | Cloudflare Tunnel token. If set, it is written to `/etc/conf.d/${cloudflared_name}` and the service is started. |

### Usage

#### Via curl (single default tunnel)

```bash
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/cloudflared-alpine/run.sh | \
  cloudflared_version=2026.10.0 cloudflare_token=YOUR_TOKEN sh
```

#### Multiple tunnels

```bash
# First tunnel
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/cloudflared-alpine/run.sh | \
  cloudflared_name=cloudflared-web cloudflare_token=TOKEN_1 sh

# Second tunnel
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/cloudflared-alpine/run.sh | \
  cloudflared_name=cloudflared-ssh cloudflare_token=TOKEN_2 sh
```

This creates two independent services: `/etc/init.d/cloudflared-web` and `/etc/init.d/cloudflared-ssh`, each with their own config and token.

#### Via curl (configure token afterwards)

```bash
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/cloudflared-alpine/run.sh | \
  cloudflared_name=cloudflared-web sh
sed -i 's/^token=.*/token="YOUR_TOKEN"/' /etc/conf.d/cloudflared-web
rc-service cloudflared-web start
```

#### From file

```bash
chmod +x cloudflared-alpine/run.sh
cloudflared_name=cloudflared-web cloudflared_version=2026.10.0 cloudflare_token=YOUR_TOKEN ./cloudflared-alpine/run.sh
```

### Architecture Mapping

| `uname -m` | Downloaded binary |
|---|---|
| `x86_64`, `amd64` | `cloudflared-linux-amd64` |
| `aarch64`, `arm64` | `cloudflared-linux-arm64` |
| `armv7l`, `armv6l`, `armv8l`, `arm` | `cloudflared-linux-armhf` |
| `armv5*`, `armv4*` | `cloudflared-linux-arm` |

### Notes

- The OpenRC service uses `supervisor=supervise-daemon` so OpenRC restarts cloudflared if it exits unexpectedly.
- The service will fail to start with a clear error if `token` is empty in its config file.
- The script will not overwrite an existing token unless `cloudflare_token` is supplied.
- The binary is only re-downloaded if it is missing or not the requested version, so re-running the script to add another tunnel is fast.

## `cloudflared-debian/run.sh`

Installs [cloudflared](https://github.com/cloudflare/cloudflared) on Debian/Ubuntu with a systemd service. Equivalent to the Alpine recipe, but uses systemd instead of OpenRC.

### Variables

| Variable | Default | Description |
|---|---|---|
| `cloudflared_name` | `cloudflared` | Name of this tunnel instance. Each unique name gets its own systemd service and config file. |
| `cloudflared_version` | latest GitHub release | cloudflared release version to install. |
| `cloudflare_token` | *(optional)* | Cloudflare Tunnel token. If set, it is written to `/etc/default/${cloudflared_name}` and the service is started. |

### Usage

```bash
# Single default tunnel
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/cloudflared-debian/run.sh | \
  cloudflared_version=2026.10.0 cloudflare_token=YOUR_TOKEN sh

# Multiple named tunnels
# First tunnel
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/cloudflared-debian/run.sh | \
  cloudflared_name=cloudflared-web cloudflare_token=TOKEN_1 sh

# Second tunnel
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/cloudflared-debian/run.sh | \
  cloudflared_name=cloudflared-ssh cloudflare_token=TOKEN_2 sh

# Upgrade
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/cloudflared-debian/run.sh | \
  cloudflared_version=2026.10.0 sh
```

### Notes

- The binary is installed to `/usr/local/bin/cloudflared`.
- Each instance gets its own config at `/etc/default/${cloudflared_name}` and log at `/var/log/${cloudflared_name}.log`.
- Upgrades parse the installed version and restart the affected service automatically.

## `cloudflared-debian/uninstall.sh`

Removes a cloudflared tunnel instance by name. By default the shared binary is left in place so other instances continue to work; set `cloudflared_purge=1` to remove the binary as well (only if no other instances remain).

### Variables

| Variable | Default | Description |
|---|---|---|
| `cloudflared_name` | `cloudflared` | Name of the instance to remove. |
| `cloudflared_purge` | `0` | Set to `1` to remove `/usr/local/bin/cloudflared` if no other instances exist. |

### Usage

```bash
# Remove a single named instance
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/cloudflared-debian/uninstall.sh | \
  cloudflared_name=cloudflared-web sh

# Remove the default instance and purge the binary if nothing else remains
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/cloudflared-debian/uninstall.sh | \
  cloudflared_purge=1 sh
```

## `netbird-alpine/run.sh`

Installs the [Netbird](https://github.com/netbirdio/netbird) agent on Alpine Linux using the official release binaries. Netbird handles its own OpenRC service. The script installs the binary, creates the service, enables it on boot, and leaves a `/root/netbird.info.txt` file with the manual login steps.

### Variables

| Variable | Default | Description |
|---|---|---|
| `netbird_version` | `0.74.4` | Netbird release version to install. The `v` prefix is optional. |

### Usage

```bash
# Install
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/netbird-alpine/run.sh | sh

# Install a specific version
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/netbird-alpine/run.sh | \
  netbird_version=0.74.4 sh
```

After installation, follow the steps in `/root/netbird.info.txt`:

```bash
rc-service netbird start
HOME=/root netbird login --setup-key YOUR_SETUP_KEY
HOME=/root netbird up
```

### Notes

- The binary is only re-downloaded if it is missing or not the requested version.
- Netbird requires `/dev/net/tun`; the script attempts to load the `tun` module and fails if it is unavailable.
- The `nftables` package and `nf_tables` kernel module are required for Netbird’s firewall manager; the script installs and loads them.
- The `netbird service install` command creates the OpenRC init script; the recipe then adds it to the default runlevel.

## `netbird-alpine/uninstall.sh`

Removes Netbird and its OpenRC service.

```bash
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/netbird-alpine/uninstall.sh | sh
```

## `cloudflared-alpine/uninstall.sh`

Removes a cloudflared tunnel instance by name. By default the shared binary is left in place so other instances continue to work; set `cloudflared_purge=1` to remove the binary as well (only if no other instances remain).

### Variables

| Variable | Default | Description |
|---|---|---|
| `cloudflared_name` | `cloudflared` | Name of the instance to remove. |
| `cloudflared_purge` | `0` | Set to `1` to remove `/usr/local/bin/cloudflared` if no other instances exist. |

### Usage

```bash
# Remove a single named instance
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/cloudflared-alpine/uninstall.sh | \
  cloudflared_name=cloudflared-web sh

# Remove the default instance and purge the binary if nothing else remains
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/cloudflared-alpine/uninstall.sh | \
  cloudflared_purge=1 sh
```

## `technitium-dns-alpine/run.sh`

Installs [Technitium DNS Server](https://github.com/TechnitiumSoftware/DnsServer) on Alpine Linux.

Technitium DNS Server requires IPv6 support, so make sure you run `optimised-alpine/run.sh` with `disable_ipv6=0` first.

### What it does

- Installs `aspnetcore10-runtime` and `libcap`.
- Creates a `dns-server` user/group.
- Downloads the latest portable build from Technitium's CDN.
- Extracts it to `/opt/technitium/dns`.
- Creates `/etc/dns` for persistent config.
- Installs and enables an OpenRC service with `cap_net_bind_service` so it can bind port 53.

### Variables

| Variable | Default | Description |
|---|---|---|
| `technitium_url` | latest portable build | URL to the Technitium DNS Server portable tarball. |

### Usage

```bash
# First, optimise Alpine while keeping IPv6
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/optimised-alpine/run.sh | \
  disable_ipv6=0 swap_size=512 sh

# Then install Technitium DNS Server
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/technitium-dns-alpine/run.sh | sh
```

After installation, the web UI is available on port `5380` with default credentials `admin` / `admin`.

### Notes

- The portable build is downloaded from `https://download.technitium.com/dns/DnsServerPortable.tar.gz`.
- Logs are written to `/var/log/technitium-dns.log`.
- Config is persisted in `/etc/dns`.

## `technitium-dns-alpine/uninstall.sh`

Removes Technitium DNS Server. Config in `/etc/dns` is preserved.

```bash
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/technitium-dns-alpine/uninstall.sh | sh
```

## `gitea-alpine/run.sh`

Installs [Gitea](https://about.gitea.com/) on Alpine Linux with SQLite (no separate database server required).

### What it does

- Downloads the official Gitea binary from GitHub releases.
- Creates a `git` user and `/var/lib/gitea` data directory.
- Creates a minimal `/etc/gitea/app.ini` using SQLite.
- Installs and enables an OpenRC service.
- Optionally creates an admin user from environment variables.

### Variables

| Variable | Default | Description |
|---|---|---|
| `gitea_version` | latest GitHub release | Gitea release version. |
| `gitea_http_port` | `3000` | Web UI and HTTP Git port. |
| `gitea_ssh_port` | `2222` | Internal SSH port for `git+ssh` (avoid 22 to not conflict with host SSH). |
| `gitea_domain` | `localhost` | Domain used in URLs. |
| `gitea_admin_user` | *(optional)* | Admin username to auto-create. |
| `gitea_admin_password` | *(optional)* | Admin password to auto-create. |
| `gitea_admin_email` | `admin@example.com` | Admin email address. |

### Usage

```bash
# Basic install
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/gitea-alpine/run.sh | sh

# With admin user pre-created
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/gitea-alpine/run.sh | \
  gitea_domain=git.example.com gitea_admin_user=admin \
  gitea_admin_password='ChangeMe!' sh
```

After installation, the web UI is available on port `3000`.

### SSH notes

The recipe defaults Gitea SSH to internal port `2222` so it does not conflict with the host SSH on port `22`. Map your external port to internal `2222` at your provider if you want git+ssh access.

## `gitea-alpine/uninstall.sh`

Removes Gitea. Config in `/etc/gitea` and repositories in `/var/lib/gitea` are preserved.

```bash
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/gitea-alpine/uninstall.sh | sh
```

## `rqlite-alpine/run.sh`

Installs [rqlite](https://github.com/rqlite/rqlite) on Alpine Linux — a lightweight, distributed SQL database built on SQLite.

### What it does

- Downloads the official rqlite binary release from GitHub.
- Creates an `rqlite` user and `/var/lib/rqlite` data directory.
- Installs the `rqlited` server, `rqlite` CLI, and `rqbench` tools.
- Installs and enables an OpenRC service.
- Runs a single-node cluster by default.

### Variables

| Variable | Default | Description |
|---|---|---|
| `rqlite_version` | latest GitHub release | rqlite release version. |
| `rqlite_http_port` | `4001` | HTTP API port. |
| `rqlite_raft_port` | `4002` | Raft cluster port. |
| `rqlite_data_dir` | `/var/lib/rqlite` | Data directory. |

### Usage

```bash
# Basic install
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/rqlite-alpine/run.sh | sh

# Custom ports
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/rqlite-alpine/run.sh | \
  rqlite_http_port=8080 rqlite_raft_port=8081 sh
```

After installation, the HTTP API is available on port `4001` by default.

### Example

```bash
curl -XPOST 'http://localhost:4001/db/execute' \
  -H 'Content-Type: application/json' \
  -d '["CREATE TABLE foo (id INTEGER PRIMARY KEY, name TEXT)"]'

curl -XPOST 'http://localhost:4001/db/query' \
  -H 'Content-Type: application/json' \
  -d '["SELECT * FROM foo"]'
```

## `rqlite-alpine/uninstall.sh`

Removes rqlite. Config in `/etc/rqlite` and data in `/var/lib/rqlite` are preserved.

```bash
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/rqlite-alpine/uninstall.sh | sh
```

## Development

Both scripts are validated with `sh -n` and `dash -n` before commit to ensure POSIX compatibility.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
