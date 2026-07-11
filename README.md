# TierHive Recipes

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)

A collection of Alpine Linux installation and optimisation recipes for use with [TierHive](https://tierhive.com/) and other VPS automation workflows. Each recipe is a self-contained POSIX `sh` script that can be fetched via `curl` and executed directly, or embedded into a provisioning pipeline.

All scripts are written for **Alpine Linux** and assume they are run as **root**.

## Repository Layout

```
tierhive/
├── optimised-alpine/
│   └── run.sh      # Harden and optimise Alpine 3.24.x for low-RAM headless servers
├── cloudflared-alpine/
│   ├── run.sh      # Install cloudflared with an OpenRC service
│   └── uninstall.sh # Remove a cloudflared instance
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

### Usage

#### Via curl

```bash
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/optimised-alpine/run.sh | swap_size=512 sh
```

#### From file

```bash
chmod +x optimised-alpine/run.sh
swap_size=512 ./optimised-alpine/run.sh
```

### Notes

- The script is POSIX `sh` compatible and does not require Bash.
- Progress is logged to `/root/recipe.log` and mirrored to stdout.
- A swap file is created early so memory-heavy steps such as `mkinitfs` have backing swap.

## `cloudflared-alpine/run.sh`

Installs [cloudflared](https://github.com/cloudflare/cloudflared) on Alpine Linux and configures it as an OpenRC service using `supervise-daemon`. Supports multiple independent tunnel instances by giving each one a unique name.

### Variables

| Variable | Default | Description |
|---|---|---|
| `cloudflared_name` | `cloudflared` | Name of this tunnel instance. Each unique name gets its own OpenRC service and config file. |
| `cloudflared_version` | `2026.7.1` | cloudflared release version to install. |
| `cloudflare_token` | *(optional)* | Cloudflare Tunnel token. If set, it is written to `/etc/conf.d/${cloudflared_name}` and the service is started. |

### Usage

#### Via curl (single default tunnel)

```bash
curl -fsSL https://raw.githubusercontent.com/matthewgall/tierhive/main/cloudflared-alpine/run.sh | \
  cloudflared_version=2026.7.1 cloudflare_token=YOUR_TOKEN sh
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
cloudflared_name=cloudflared-web cloudflared_version=2026.7.1 cloudflare_token=YOUR_TOKEN ./cloudflared-alpine/run.sh
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

## Development

Both scripts are validated with `sh -n` and `dash -n` before commit to ensure POSIX compatibility.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
