#!/bin/sh

# Exit immediately on error and treat unset variables as errors.
set -eu

LOG_PIPE="/tmp/runsh-log.$$"
LOG_PID=""

start_logging() {
    mkfifo "$LOG_PIPE"
    tee -a /root/recipe.log < "$LOG_PIPE" &
    LOG_PID=$!
    exec > "$LOG_PIPE" 2>&1
}

cleanup() {
    rc=$1
    # Do not let cleanup errors mask the original exit status.
    set +e
    if [ "$rc" -ne 0 ]; then
        echo "ERROR: Recipe failed with exit code $rc" >&2
    fi
    # Detach from the FIFO before tearing it down so the kill itself
    # does not fail with SIGPIPE.
    exec >/dev/null 2>&1
    if [ -n "$LOG_PID" ]; then
        kill "$LOG_PID" 2>/dev/null
    fi
    rm -f "$LOG_PIPE"
}

start_logging
trap 'cleanup $?' EXIT

# When run via curl | sh, $0 is "sh" rather than the script path.
[ -f "$0" ] && cp "$0" /root/installScript.sh.txt

echo '######################################'
echo '#                                    #'
echo '#             Optimising             #'
echo '#                                    #'
echo '######################################'

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

# TierHive fills this in at recipe run time.
swapSize=${swap_size:-}
if [ -z "$swapSize" ]; then
    echo "ERROR: swap_size variable is not set." >&2
    exit 1
fi
case "$swapSize" in
    ''|*[!0-9]*)
        echo "ERROR: swap_size must be a positive integer (MB). Got: '$swapSize'" >&2
        exit 1
        ;;
esac
if [ "$swapSize" -le 0 ]; then
    echo "ERROR: swap_size must be a positive integer (MB). Got: '$swapSize'" >&2
    exit 1
fi

swapFile="/swapfile"

backup_file() {
    file=$1
    if [ -f "$file" ]; then
        backup="${file}.bak_$(date +%Y%m%d_%H%M%S)"
        cp -a "$file" "$backup"
        echo "Backed up $file -> $backup"
    fi
}

ensure_kernel_opt() {
    opt=$1
    file=$2

    if ! grep -qE '^default_kernel_opts=' "$file"; then
        echo "ERROR: default_kernel_opts not found in $file" >&2
        return 1
    fi

    if grep -E '^default_kernel_opts=' "$file" | grep -qF "$opt"; then
        echo "Kernel option '$opt' already present."
        return 0
    fi

    sed -i "/^default_kernel_opts=/ s/\"$/ $opt\"/" "$file"

    if grep -E '^default_kernel_opts=' "$file" | grep -qF "$opt"; then
        echo "Added kernel option '$opt'."
    else
        echo "ERROR: Failed to add kernel option '$opt' to $file" >&2
        return 1
    fi
}

#
# Low-RAM tuning
#
echo "------------------------------------"
echo "Tuning Alpine for low-RAM headless operation"
echo "------------------------------------"

cat > /etc/modprobe.d/blacklist-unnecessary.conf << 'EOF'
# Graphics (headless server)
blacklist drm
blacklist drm_kms_helper
blacklist simpledrm
blacklist virtio_gpu
blacklist fb

# KVM (not nesting VMs)
blacklist kvm
blacklist kvm_amd
blacklist kvm_intel

# Legacy devices
blacklist floppy
blacklist cdrom
blacklist sr_mod
blacklist isofs

# HID/input (headless)
blacklist hid
blacklist usbhid
blacklist hid_generic
blacklist psmouse
blacklist mousedev

# Wrong cloud drivers (not GCP/AWS)
blacklist gve
blacklist ena

# Force block DRM (blacklist alone does not work, ACPI triggers it)
install drm /bin/true
install drm_kms_helper /bin/true
install simpledrm /bin/true
install fb /bin/true

# USB (not needed on VPS)
blacklist usbcore
blacklist xhci_hcd
blacklist xhci_pci
blacklist usb_common

# I2C (not needed)
blacklist i2c_core
blacklist i2c_smbus
blacklist i2c_piix4

# Input (headless)
blacklist evdev
blacklist button

# Misc not needed
blacklist loop
blacklist ata_generic
blacklist i6300esb
blacklist qemu_fw_cfg

# Memory ballooning
blacklist virtio_balloon

# Hard block loop device (blacklist entry alone is not always sufficient)
install loop /bin/true
EOF

backup_file /etc/mkinitfs/mkinitfs.conf
sed -i 's/^features=.*/features="base ext4 virtio"/' /etc/mkinitfs/mkinitfs.conf

backup_file /etc/update-extlinux.conf
# Remove unneeded modules from the bootloader module list if present.
sed -i 's/,usb-storage,ext4,ena,gve/,ext4/g' /etc/update-extlinux.conf
# Ensure kernel options are present; append each only if not already there.
for opt in ipv6.disable=1 audit=0 nowatchdog; do
    ensure_kernel_opt "$opt" /etc/update-extlinux.conf
done

# Disable IPv6 sysctl entries so they do not error at boot when IPv6 is disabled
# at the kernel level.
ipv6_sysctl_file="/usr/lib/sysctl.d/00-alpine.conf"
if [ -f "$ipv6_sysctl_file" ]; then
    backup_file "$ipv6_sysctl_file"
    if grep -qE '^[[:space:]]*net\.ipv6' "$ipv6_sysctl_file"; then
        sed -i '/^[[:space:]]*net\.ipv6/s/^[[:space:]]*/# /' "$ipv6_sysctl_file"
        echo "Disabled IPv6 sysctl entries in $ipv6_sysctl_file"
    else
        echo "IPv6 sysctl entries already disabled or absent."
    fi
else
    echo "Warning: $ipv6_sysctl_file not found; skipping IPv6 sysctl modification." >&2
fi

cat > /etc/sysctl.d/10-minvps.conf << 'EOF'
# Reduce network socket buffers
net.core.rmem_default = 32768
net.core.wmem_default = 32768
net.core.rmem_max = 131072
net.core.wmem_max = 131072
net.core.netdev_max_backlog = 64
net.core.somaxconn = 128

# Reclaim inode and dentry caches more aggressively under memory pressure
vm.vfs_cache_pressure = 500

# Reduce PID table overhead
kernel.pid_max = 4096

# Dirty page writeback thresholds
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10

# Disable watchdog
kernel.watchdog = 0

# Encourage swapping on low-RAM systems
vm.swappiness = 70
EOF

echo "Regenerating initramfs..."
mkinitfs

#
# Time services
#
echo "---------------------------------"
echo "Replacing chronyd with ntpd"
echo "---------------------------------"

if [ -f /etc/init.d/chronyd ]; then
    rc-service chronyd stop 2>/dev/null || true
    rc-update del chronyd default 2>/dev/null || true
fi

for pkg in chrony chrony-openrc; do
    if apk info -e "$pkg" >/dev/null 2>&1; then
        apk del "$pkg"
    fi
done

if [ -f /etc/init.d/ntpd ]; then
    rc-update add ntpd default
    rc-service ntpd start 2>/dev/null || true
    echo "ntpd enabled for default runlevel."
else
    echo "Warning: ntpd service not found; skipping enable." >&2
fi

#
# Swap configuration
#
echo "---------------------------------"
echo "Checking swap status"
echo "---------------------------------"

if [ -e "$swapFile" ]; then
    if awk 'NR>1 {print $1}' /proc/swaps | grep -qx "$swapFile"; then
        echo "Swap file already active at $swapFile; skipping creation."
    else
        echo "ERROR: $swapFile exists but is not active. Aborting to avoid data loss." >&2
        exit 1
    fi
else
    available_mb=$(df -m / | awk 'NR==2 {print $4}')
    if [ "$available_mb" -lt "$(( swapSize + 100 ))" ]; then
        echo "ERROR: Not enough disk space. Needed: $(( swapSize + 100 )) MB, available: $available_mb MB" >&2
        exit 1
    fi

    echo "---------------------------------"
    echo "Allocating ${swapSize} MiB swap file at $swapFile"
    echo "---------------------------------"
    dd if=/dev/zero of="$swapFile" bs=1M count="$swapSize"

    echo "---------------------------------"
    echo "Initializing and enabling swap"
    echo "---------------------------------"
    chmod 600 "$swapFile"
    mkswap "$swapFile"
    swapon "$swapFile"
fi

echo "---------------------------------"
echo "Persisting swap in /etc/fstab"
echo "---------------------------------"
if grep -qE "^[[:space:]]*${swapFile}[[:space:]]" /etc/fstab; then
    echo "Swap already persisted in /etc/fstab"
else
    echo "$swapFile none swap defaults 0 0" >> /etc/fstab
    echo "Added swap entry to /etc/fstab"
fi

free -h

#
# Enable zswap
#
echo "---------------------------------"
echo "Enabling zswap"
echo "---------------------------------"

zswap_enabled_file="/sys/module/zswap/parameters/enabled"
if [ -f "$zswap_enabled_file" ]; then
    if [ "$(cat "$zswap_enabled_file")" = "1" ]; then
        echo "zswap already active."
    else
        echo 1 > "$zswap_enabled_file"
        echo "zswap enabled for current session."
    fi
else
    echo "Warning: $zswap_enabled_file not found. ZSwap may not be available." >&2
fi

CFG_FILE="/etc/update-extlinux.conf"
BOOT_CFG="/boot/extlinux.conf"

echo "Updating bootloader configuration"

backup_file "$CFG_FILE"
[ -f "$BOOT_CFG" ] && backup_file "$BOOT_CFG"

if grep -qF "zswap.enabled" "$CFG_FILE"; then
    echo "zswap already configured in bootloader; no changes made."
else
    echo "Adding zswap to kernel command line"
    ensure_kernel_opt "zswap.enabled=1" "$CFG_FILE"
fi

# Reduce bootloader delay.
if grep -qE '^timeout=1([[:space:]]|$)' "$CFG_FILE"; then
    echo "Bootloader timeout already set to 1 second."
else
    sed -i 's/^timeout=[0-9][0-9]*/timeout=1/' "$CFG_FILE"
    echo "Reduced bootloader timeout to 1 second."
fi

echo "Applying bootloader configuration"
update-extlinux

echo "zswap will be active after reboot"
echo "Optimisation complete."
