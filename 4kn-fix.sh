#!/usr/bin/env bash
# 4kn-fix.sh — Linux Drive Diagnostic & Fix Toolkit
# Handles: UAS driver issues, dirty filesystems, 4KN alignment,
#          SMART health, mount problems, write-protection
# Usage: sudo bash 4kn-fix.sh
# Repo:  https://github.com/Sir-MmD/4KN-Fix
# shellcheck disable=SC2015  # A && B || C patterns are intentional (B is a simple log call)

VERSION="2.0.0"

# ─── Strict mode ────────────────────────────────────────────────────────────
set -uo pipefail

# ─── Color support ──────────────────────────────────────────────────────────
setup_colors() {
    if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]] || [[ "${TERM:-}" == "dumb" ]]; then
        RED="" GREEN="" YELLOW="" BLUE="" CYAN="" BOLD="" RESET=""
        USE_COLOR=false
    else
        RED=$'\033[0;31m'   GREEN=$'\033[0;32m' YELLOW=$'\033[1;33m'
        BLUE=$'\033[0;34m'  CYAN=$'\033[0;36m'  BOLD=$'\033[1m'
        RESET=$'\033[0m'
        USE_COLOR=true
    fi
}

log()    { printf '%s[*]%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()     { printf '%s[✓]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn()   { printf '%s[!]%s %s\n' "$YELLOW" "$RESET" "$*"; }
err()    { printf '%s[✗]%s %s\n' "$RED" "$RESET" "$*" >&2; }
die()    { err "$*"; exit 1; }
banner() { printf '\n%s%s─── %s ───%s\n\n' "$BOLD" "$CYAN" "$*" "$RESET"; }

# Interactive read: reads from /dev/tty when stdin isn't a terminal (e.g. curl|bash).
# Exits gracefully if /dev/tty is also unavailable.
# Sets the variable named by $1 to the user's input.
prompt_read() {
    local -n _prompt_ref="$1"
    if [[ -t 0 ]]; then
        IFS= read -r _prompt_ref
    elif { true </dev/tty; } 2>/dev/null; then
        IFS= read -r _prompt_ref </dev/tty
    else
        die "No interactive terminal available. Download the script and run it directly."
    fi
}

# ─── Temp files & cleanup ──────────────────────────────────────────────────
TMPDIR_4KN=""

cleanup() {
    [[ -n "$TMPDIR_4KN" && -d "$TMPDIR_4KN" ]] && rm -rf "$TMPDIR_4KN"
}

on_interrupt() {
    printf '\n%s[!]%s Interrupted. Cleaning up...\n' "$YELLOW" "$RESET"
    exit 130
}

trap cleanup EXIT
trap on_interrupt INT

make_tmpdir() {
    if [[ -z "$TMPDIR_4KN" ]]; then
        TMPDIR_4KN=$(mktemp -d /tmp/4kn-fix.XXXXXX)
    fi
}

# ─── CLI flags ──────────────────────────────────────────────────────────────
show_help() {
    cat <<'EOF'
4KN-Fix — Linux Drive Diagnostic & Fix Toolkit

Usage: sudo bash 4kn-fix.sh [OPTIONS]

Options:
  -h, --help       Show this help message
  -V, --version    Show version
  --no-color       Disable colored output

Interactive tool that scans all drives, diagnoses issues, and offers
context-sensitive fixes:

  • USB drives with UAS driver errors (any sector size)
  • Dirty/corrupt filesystems (NTFS, ext4, exFAT, btrfs, xfs, vfat)
  • Drives that won't mount
  • 4KN-specific alignment/compatibility issues
  • SMART health problems
  • Write-protection false positives

Run as root (or with sudo) for full functionality.
EOF
}

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            -h|--help)     show_help; exit 0 ;;
            -V|--version)  echo "4kn-fix $VERSION"; exit 0 ;;
            --no-color)    NO_COLOR=1 ;;
            *)             die "Unknown option: $arg (try --help)" ;;
        esac
    done
}

# ─── Root escalation ───────────────────────────────────────────────────────
ensure_root() {
    if [[ $EUID -ne 0 ]]; then
        if command -v sudo &>/dev/null; then
            exec sudo bash "$0" "$@"
        else
            die "Run as root or install sudo."
        fi
    fi
}

# ─── Real user (the one who invoked sudo) ──────────────────────────────────
detect_real_user() {
    REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
    REAL_UID=$(id -u "$REAL_USER" 2>/dev/null || echo 0)
    REAL_GID=$(id -g "$REAL_USER" 2>/dev/null || echo 0)
}

# ─── Container detection ──────────────────────────────────────────────────
check_container() {
    local in_container=false
    if [[ -f /.dockerenv ]]; then
        in_container=true
    elif [[ -f /run/.containerenv ]]; then
        in_container=true
    elif grep -qE '(docker|lxc|containerd)' /proc/1/cgroup 2>/dev/null; then
        in_container=true
    fi
    if $in_container; then
        warn "Running inside a container — permanent fixes (modprobe, initramfs) won't persist."
        echo
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# DISTRO DETECTION & PACKAGE MANAGEMENT
# ═════════════════════════════════════════════════════════════════════════════
DISTRO_FAMILY=""

detect_distro() {
    if [[ ! -f /etc/os-release ]]; then
        warn "Cannot detect distro: /etc/os-release missing."
        DISTRO_FAMILY="unknown"
        return
    fi
    # shellcheck source=/dev/null
    source /etc/os-release
    local id="${ID,,}" like="${ID_LIKE,,}"

    if   [[ "$id" == "arch"      || "$like" == *"arch"*    ]]; then DISTRO_FAMILY="arch"
    elif [[ "$id" == "debian"    || "$id" == "ubuntu"
         || "$id" == "linuxmint" || "$like" == *"debian"*  ]]; then DISTRO_FAMILY="debian"
    elif [[ "$id" == "fedora"    || "$like" == *"fedora"*  ]]; then DISTRO_FAMILY="fedora"
    elif [[ "$id" == "almalinux" || "$id" == "rocky"
         || "$id" == "rhel"      || "$id" == "centos"
         || "$like" == *"rhel"*  ]]; then                           DISTRO_FAMILY="rhel"
    elif [[ "$id" == "opensuse"* || "$like" == *"suse"*    ]]; then DISTRO_FAMILY="suse"
    elif [[ "$id" == "gentoo"    || "$like" == *"gentoo"*  ]]; then DISTRO_FAMILY="gentoo"
    elif [[ "$id" == "void"      ]]; then                           DISTRO_FAMILY="void"
    elif [[ "$id" == "alpine"    ]]; then                           DISTRO_FAMILY="alpine"
    else
        warn "Unknown distro '$id'; will try to continue without auto-install."
        DISTRO_FAMILY="unknown"
    fi
}

# Lazy install: only install a tool when an action needs it
# Usage: ensure_cmd <command> <arch-pkg> <debian-pkg> <fedora-pkg> <rhel-pkg> <suse-pkg> <gentoo-pkg> <void-pkg> <alpine-pkg>
ensure_cmd() {
    local cmd="$1"
    command -v "$cmd" &>/dev/null && return 0

    local arch_pkg="$2" deb_pkg="$3" fed_pkg="$4" rhel_pkg="$5"
    local suse_pkg="${6:-}" gentoo_pkg="${7:-}" void_pkg="${8:-}" alpine_pkg="${9:-}"

    log "Installing $cmd..."

    case "$DISTRO_FAMILY" in
        arch)    pacman -Sy --noconfirm --needed "$arch_pkg" ;;
        debian)  apt-get update -qq && apt-get install -y "$deb_pkg" ;;
        fedora)  dnf install -y "$fed_pkg" ;;
        rhel)
            if [[ "$rhel_pkg" == "ntfsprogs" || "$rhel_pkg" == "ntfs-3g" ]] && \
               ! rpm -q epel-release &>/dev/null; then
                log "Enabling EPEL repository..."
                dnf install -y epel-release
            fi
            dnf install -y "$rhel_pkg"
            ;;
        suse)    zypper install -y "$suse_pkg" ;;
        gentoo)  [[ -n "$gentoo_pkg" ]] && emerge --ask=n "$gentoo_pkg" ;;
        void)    [[ -n "$void_pkg" ]] && xbps-install -y "$void_pkg" ;;
        alpine)  [[ -n "$alpine_pkg" ]] && apk add "$alpine_pkg" ;;
        *)
            warn "Cannot auto-install '$cmd'. Please install it manually."
            return 1
            ;;
    esac

    if command -v "$cmd" &>/dev/null; then
        ok "$cmd installed."
    else
        warn "Failed to install $cmd."
        return 1
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# SYSFS & USB HELPERS
# ═════════════════════════════════════════════════════════════════════════════

sysfs_read() { cat "$1" 2>/dev/null | tr -d '[:space:]'; }
sysfs_read_raw() { cat "$1" 2>/dev/null; }

# List USB interface IDs bound to a driver
list_driver_ifaces() {
    local drv_path="/sys/bus/usb/drivers/$1"
    [[ -d "$drv_path" ]] || return 0
    local entry name
    for entry in "$drv_path"/*/; do
        name=$(basename "$entry")
        [[ "$name" =~ ^(bind|unbind|module|new_id|remove_id|uevent)$ ]] && continue
        [[ -d "$entry" ]] && echo "$name"
    done
}

# Interface ID → USB device base (e.g. "4-4:1.0" → "4-4")
iface_to_dev() { echo "${1%:*}"; }

# Read VID:PID and product name for a USB interface
usb_vid_pid() {
    local dev
    dev=$(iface_to_dev "$1")
    local base="/sys/bus/usb/devices/$dev"
    local vid pid
    vid=$(sysfs_read "$base/idVendor")
    pid=$(sysfs_read "$base/idProduct")
    echo "$vid:$pid"
}

usb_product_name() {
    local dev
    dev=$(iface_to_dev "$1")
    local base="/sys/bus/usb/devices/$dev"
    local mfr prod
    mfr=$(sysfs_read_raw "$base/manufacturer" | xargs)
    prod=$(sysfs_read_raw "$base/product" | xargs)
    if [[ -n "$mfr" && -n "$prod" ]]; then
        echo "$mfr $prod"
    elif [[ -n "$prod" ]]; then
        echo "$prod"
    elif [[ -n "$mfr" ]]; then
        echo "$mfr"
    else
        echo "Unknown USB device"
    fi
}

# Find /dev/sdX for a USB interface bound to uas or usb-storage
block_dev_for_iface() {
    local iface="$1"
    for drv in uas usb-storage; do
        local base="/sys/bus/usb/drivers/$drv/$iface"
        [[ -d "$base" ]] || continue
        local block_dir
        block_dir=$(find "$base" -maxdepth 5 -name "block" -type d 2>/dev/null | head -1)
        [[ -z "$block_dir" ]] && continue
        local found
        found=$(find "$block_dir/" -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null | head -1)
        [[ -n "$found" ]] && { echo "$found"; return 0; }
    done
}

# Detect transport type for a block device
detect_transport() {
    local dev="$1"  # e.g. sda, nvme0n1
    local tran
    tran=$(lsblk -dno TRAN "/dev/$dev" 2>/dev/null | xargs)
    if [[ -n "$tran" ]]; then
        echo "${tran^^}"
        return
    fi
    # Fallback: check sysfs
    if [[ "$dev" == nvme* ]]; then
        echo "NVMe"
    elif [[ -L "/sys/block/$dev" ]]; then
        local path
        path=$(readlink -f "/sys/block/$dev")
        if [[ "$path" == */usb* ]]; then
            echo "USB"
        elif [[ "$path" == */ata* ]]; then
            echo "SATA"
        else
            echo "unknown"
        fi
    else
        echo "unknown"
    fi
}

# Check if a USB block device is using the UAS driver
is_uas_device() {
    local dev="$1"
    [[ -L "/sys/block/$dev" ]] || return 1
    local path
    path=$(readlink -f "/sys/block/$dev")
    [[ "$path" == */uas/* ]] && return 0
    # Also check driver symlinks
    local iface
    iface=$(find_usb_iface_for_block "$dev")
    [[ -z "$iface" ]] && return 1
    [[ -d "/sys/bus/usb/drivers/uas/$iface" ]] && return 0
    return 1
}

# Find the USB interface for a block device
find_usb_iface_for_block() {
    local dev="$1"
    # Try UAS first, then usb-storage
    for drv in uas usb-storage; do
        local iface
        while IFS= read -r iface; do
            [[ -z "$iface" ]] && continue
            local blk
            blk=$(block_dev_for_iface "$iface")
            if [[ "$blk" == "$dev" ]]; then
                echo "$iface"
                return 0
            fi
        done < <(list_driver_ifaces "$drv")
    done
}

# Check dmesg for UAS errors on a device
dmesg_has_uas_errors() {
    local dev="$1"
    dmesg 2>/dev/null | grep -qiE "\[${dev}\].*(err|FAILED|offline|cmplt err|sense key|abort|reset)" 2>/dev/null
}

# Check dmesg for I/O errors on a device
dmesg_has_io_errors() {
    local dev="$1"
    dmesg 2>/dev/null | grep -qiE "\[${dev}\].*(I/O error|buffer I/O|logical block)" 2>/dev/null
}

# Check if a device is write-protected
is_write_protected() {
    local dev="$1"
    local ro
    ro=$(sysfs_read "/sys/block/$dev/ro")
    [[ "$ro" == "1" ]]
}

# ═════════════════════════════════════════════════════════════════════════════
# FILESYSTEM HELPERS
# ═════════════════════════════════════════════════════════════════════════════

# Check if an NTFS partition has the dirty flag set
is_ntfs_dirty() {
    local part="$1"
    if command -v ntfsinfo &>/dev/null; then
        ntfsinfo -m "$part" 2>/dev/null | grep -qi "dirty\|Volume is.*not clean" && return 0
    fi
    # Fallback: try ntfsfix dry-run
    if command -v ntfsfix &>/dev/null; then
        ntfsfix -n "$part" 2>&1 | grep -qi "dirty\|is not clean\|was not properly unmounted" && return 0
    fi
    return 1
}

# Check if an ext filesystem needs repair
is_ext_dirty() {
    local part="$1"
    if command -v tune2fs &>/dev/null; then
        local state
        state=$(tune2fs -l "$part" 2>/dev/null | grep "Filesystem state:" | awk '{print $NF}')
        [[ "$state" != "clean" ]] && return 0
    fi
    return 1
}

# Get partition info: name, fstype, size, label, mountpoint
# Output: tab-separated fields
get_partitions() {
    local dev="$1"
    lsblk -rno NAME,FSTYPE,SIZE,LABEL,MOUNTPOINT "/dev/$dev" 2>/dev/null | tail -n +2
}

# ═════════════════════════════════════════════════════════════════════════════
# DRIVE SCANNING & SELECTION
# ═════════════════════════════════════════════════════════════════════════════

# Global arrays for drive list
declare -a DRV_DEVS=() DRV_SIZES=() DRV_PHYS=() DRV_LOGS=()
declare -a DRV_TRANS=() DRV_BADGES=() DRV_MODELS=()
DRIVE_COUNT=0

scan_drives() {
    DRV_DEVS=() DRV_SIZES=() DRV_PHYS=() DRV_LOGS=()
    DRV_TRANS=() DRV_BADGES=() DRV_MODELS=()
    DRIVE_COUNT=0

    local dev size phy_sec log_sec model transport badges

    while IFS= read -r line; do
        dev=$(echo "$line" | awk '{print $1}')
        [[ -z "$dev" ]] && continue
        [[ "$dev" == "loop"* || "$dev" == "ram"* || "$dev" == "zram"* ]] && continue
        [[ ! -b "/dev/$dev" ]] && continue

        size=$(lsblk -dno SIZE "/dev/$dev" 2>/dev/null | xargs)
        phy_sec=$(lsblk -dno PHY-SEC "/dev/$dev" 2>/dev/null | xargs)
        log_sec=$(lsblk -dno LOG-SEC "/dev/$dev" 2>/dev/null | xargs)
        model=$(lsblk -dno MODEL "/dev/$dev" 2>/dev/null | xargs)
        transport=$(detect_transport "$dev")
        badges=""

        # Transport detail for USB
        if [[ "$transport" == "USB" ]] && is_uas_device "$dev"; then
            transport="USB (UAS)"
        fi

        # Status badges
        # 4KN badge
        if [[ "$phy_sec" == "4096" && "$log_sec" == "4096" ]]; then
            badges+=" [4KN]"
        fi

        # UAS errors (USB only)
        if [[ "$transport" == "USB (UAS)" ]] && dmesg_has_uas_errors "$dev"; then
            badges+=" [UAS ERRORS]"
        fi

        # I/O errors
        if dmesg_has_io_errors "$dev"; then
            badges+=" [I/O errors]"
        fi

        # Write-protected
        if is_write_protected "$dev"; then
            badges+=" [write-protected]"
        fi

        # Check partitions for dirty FS and unmounted
        local has_dirty=false has_unmounted=false has_partitions=false
        local dirty_fs=""
        while IFS= read -r pline; do
            local pname pfs pmnt
            pname=$(echo "$pline" | awk '{print $1}')
            pfs=$(echo "$pline" | awk '{print $2}')
            pmnt=$(echo "$pline" | awk '{print $5}')
            [[ -z "$pfs" || "$pfs" == "swap" ]] && continue
            has_partitions=true

            # Check dirty flag
            if [[ "$pfs" == ntfs* ]] && is_ntfs_dirty "/dev/$pname"; then
                has_dirty=true; dirty_fs="$pfs"
            elif [[ "$pfs" == ext* ]] && is_ext_dirty "/dev/$pname"; then
                has_dirty=true; dirty_fs="$pfs"
            fi

            # Check unmounted
            if [[ -z "$pmnt" || "$pmnt" == "-" ]]; then
                has_unmounted=true
            fi
        done < <(get_partitions "$dev")

        if $has_dirty; then
            badges+=" [dirty ${dirty_fs}]"
        fi

        if ! $has_partitions; then
            local pcount
            pcount=$(lsblk -rno NAME "/dev/$dev" 2>/dev/null | wc -l)
            if (( pcount <= 1 )); then
                badges+=" [no partitions]"
            fi
        elif $has_unmounted; then
            badges+=" [not mounted]"
        fi

        # If no issues, show ok
        if [[ -z "$badges" ]]; then
            badges=" [ok]"
        fi

        DRV_DEVS+=("$dev")
        DRV_SIZES+=("$size")
        DRV_PHYS+=("$phy_sec")
        DRV_LOGS+=("$log_sec")
        DRV_TRANS+=("$transport")
        DRV_BADGES+=("$badges")
        DRV_MODELS+=("$model")
        ((DRIVE_COUNT++)) || true
    done < <(lsblk -dno NAME 2>/dev/null)
}

show_drive_list() {
    printf '\n  %s4KN-Fix — Linux Drive Toolkit%s\n\n' "$BOLD" "$RESET"

    # Header
    printf '  %s#   %-12s %-7s %-11s %-14s %s%s\n' \
        "$BOLD" "Device" "Size" "Sectors" "Transport" "Status" "$RESET"
    printf '  %s\n' "──────────────────────────────────────────────────────────────────"

    local i
    for (( i=0; i<DRIVE_COUNT; i++ )); do
        local dev="${DRV_DEVS[$i]}"
        local size="${DRV_SIZES[$i]}"
        local sectors="${DRV_PHYS[$i]}/${DRV_LOGS[$i]}"
        local transport="${DRV_TRANS[$i]}"
        local badges="${DRV_BADGES[$i]}"

        # Colorize badges
        local cbadges="$badges"
        if $USE_COLOR; then
            cbadges="${cbadges//\[ok\]/${GREEN}[ok]${RESET}}"
            cbadges="${cbadges//\[4KN\]/${CYAN}[4KN]${RESET}}"
            cbadges="${cbadges//\[UAS ERRORS\]/${RED}[UAS ERRORS]${RESET}}"
            cbadges="${cbadges//\[I\/O errors\]/${RED}[I\/O errors]${RESET}}"
            cbadges="${cbadges//\[write-protected\]/${RED}[write-protected]${RESET}}"
            cbadges="${cbadges//\[not mounted\]/${YELLOW}[not mounted]${RESET}}"
            cbadges="${cbadges//\[no partitions\]/${YELLOW}[no partitions]${RESET}}"
            # dirty FS badges — match any [dirty ...]
            # shellcheck disable=SC2001
            cbadges=$(echo "$cbadges" | sed "s/\[dirty \([^]]*\)\]/${YELLOW}[dirty \1]${RESET}/g")
        fi

        printf '  %-3s /dev/%-7s %-7s %-11s %-14s%s\n' \
            "$((i+1))" "$dev" "$size" "$sectors" "$transport" "$cbadges"
    done

    printf '\n  %s0%s   Exit\n\n' "$BOLD" "$RESET"
}

select_drive() {
    while true; do
        scan_drives

        if (( DRIVE_COUNT == 0 )); then
            warn "No block devices found."
            exit 0
        fi

        show_drive_list

        local choice
        printf '  Select a drive [0-%d]: ' "$DRIVE_COUNT"
        prompt_read choice

        if [[ "$choice" == "0" ]]; then
            log "Exiting."
            exit 0
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= DRIVE_COUNT )); then
            local idx=$((choice - 1))
            SEL_DEV="${DRV_DEVS[$idx]}"
            SEL_SIZE="${DRV_SIZES[$idx]}"
            SEL_PHY="${DRV_PHYS[$idx]}"
            SEL_LOG="${DRV_LOGS[$idx]}"
            SEL_TRANSPORT="${DRV_TRANS[$idx]}"
            SEL_MODEL="${DRV_MODELS[$idx]}"
            diagnose_drive
        else
            warn "Invalid selection."
        fi
    done
}

# ═════════════════════════════════════════════════════════════════════════════
# DIAGNOSIS
# ═════════════════════════════════════════════════════════════════════════════

# Globals set by diagnosis
SEL_DEV="" SEL_SIZE="" SEL_PHY="" SEL_LOG="" SEL_TRANSPORT="" SEL_MODEL=""
# shellcheck disable=SC2034
SEL_USB_IFACE="" SEL_USB_VIDPID="" SEL_USB_DRIVER=""

declare -a ISSUES=()
declare -a ACTIONS=()
declare -a ACTION_FUNCS=()
declare -a DIRTY_PARTS=()
declare -a DIRTY_FSTYPES=()
declare -a UNMOUNTED_PARTS=()
declare -a UNMOUNTED_FSTYPES=()
HAS_UAS_ISSUE=false
HAS_DIRTY_FS=false
HAS_UNMOUNTED=false
SMART_STATUS="" # tracks state across diagnosis cycle

diagnose_drive() {
    ISSUES=()
    ACTIONS=()
    ACTION_FUNCS=()
    DIRTY_PARTS=()
    DIRTY_FSTYPES=()
    UNMOUNTED_PARTS=()
    UNMOUNTED_FSTYPES=()
    HAS_UAS_ISSUE=false
    HAS_DIRTY_FS=false
    HAS_UNMOUNTED=false
    SMART_STATUS=""
    SEL_USB_IFACE="" SEL_USB_VIDPID="" SEL_USB_DRIVER=""

    local display_name="$SEL_MODEL"
    [[ -z "$display_name" ]] && display_name="$SEL_DEV"

    banner "Diagnostics: /dev/$SEL_DEV — $display_name"

    # ── Transport info ──
    printf '  %-14s: %s' "Transport" "$SEL_TRANSPORT"
    if [[ "$SEL_TRANSPORT" == "USB (UAS)" ]]; then
        printf ' (currently using UAS driver)'
    fi
    printf '\n'

    # USB-specific info
    if [[ "$SEL_TRANSPORT" == USB* ]]; then
        SEL_USB_IFACE=$(find_usb_iface_for_block "$SEL_DEV")
        if [[ -n "$SEL_USB_IFACE" ]]; then
            SEL_USB_VIDPID=$(usb_vid_pid "$SEL_USB_IFACE")
            if [[ -d "/sys/bus/usb/drivers/uas/$SEL_USB_IFACE" ]]; then
                SEL_USB_DRIVER="uas"
            else
                SEL_USB_DRIVER="usb-storage"
            fi
            printf '  %-14s: %s\n' "USB ID" "$SEL_USB_VIDPID"
            printf '  %-14s: %s\n' "Interface" "$SEL_USB_IFACE"
        fi
    fi

    # ── Size ──
    printf '  %-14s: %s\n' "Size" "$SEL_SIZE"

    # ── Sector size ──
    local sector_label=""
    if [[ "$SEL_PHY" == "4096" && "$SEL_LOG" == "4096" ]]; then
        sector_label="4KN — native 4K"
    elif [[ "$SEL_PHY" == "4096" && "$SEL_LOG" == "512" ]]; then
        sector_label="512e — 4K physical, 512 logical"
    else
        sector_label="512n"
    fi
    printf '  %-14s: PHY=%s  LOG=%s  (%s)\n' "Sector Size" "$SEL_PHY" "$SEL_LOG" "$sector_label"

    # ── Write-protect ──
    if is_write_protected "$SEL_DEV"; then
        printf '  %-14s: %sYes%s\n' "Write Protect" "$RED" "$RESET"
    else
        printf '  %-14s: No\n' "Write Protect"
    fi

    echo
    printf '  %sIssues Found:%s\n' "$BOLD" "$RESET"

    # ── Check UAS errors (USB only) ──
    if [[ "$SEL_TRANSPORT" == "USB (UAS)" ]] && dmesg_has_uas_errors "$SEL_DEV"; then
        HAS_UAS_ISSUE=true
        ISSUES+=("UAS driver errors in dmesg")
        printf '    %s✗%s UAS driver errors in dmesg\n' "$RED" "$RESET"
    fi

    # ── Check filesystem dirty flags ──
    while IFS= read -r pline; do
        local pname pfs psize pmnt
        pname=$(echo "$pline" | awk '{print $1}')
        pfs=$(echo "$pline" | awk '{print $2}')
        psize=$(echo "$pline" | awk '{print $3}')
        pmnt=$(echo "$pline" | awk '{print $5}')
        [[ -z "$pfs" || "$pfs" == "swap" ]] && continue

        # Check dirty flag
        local dirty=false
        if [[ "$pfs" == ntfs* ]] && is_ntfs_dirty "/dev/$pname"; then
            dirty=true
        elif [[ "$pfs" == ext* ]] && is_ext_dirty "/dev/$pname"; then
            dirty=true
        fi

        if $dirty; then
            HAS_DIRTY_FS=true
            DIRTY_PARTS+=("$pname")
            DIRTY_FSTYPES+=("$pfs")
            local desc="/dev/$pname ($pfs, $psize): dirty flag set — needs repair"
            ISSUES+=("$desc")
            printf '    %s✗%s %s\n' "$RED" "$RESET" "$desc"
        fi

        # Check unmounted
        if [[ -z "$pmnt" || "$pmnt" == "-" ]]; then
            HAS_UNMOUNTED=true
            UNMOUNTED_PARTS+=("$pname")
            UNMOUNTED_FSTYPES+=("$pfs")
            local desc="/dev/$pname ($pfs, $psize): not mounted"
            ISSUES+=("$desc")
            printf '    %s✗%s %s\n' "$YELLOW" "$RESET" "$desc"
        fi
    done < <(get_partitions "$SEL_DEV")

    # ── SMART check ──
    if command -v smartctl &>/dev/null; then
        local smart_args="-H"
        if [[ "$SEL_TRANSPORT" == USB* ]]; then
            smart_args="-H -d sat"
        fi
        local smart_out
        # shellcheck disable=SC2086
        smart_out=$(smartctl $smart_args "/dev/$SEL_DEV" 2>&1) || true
        if echo "$smart_out" | grep -qi "PASSED\|OK"; then
            SMART_STATUS="PASSED"
            printf '    %s✓%s SMART: PASSED\n' "$GREEN" "$RESET"
        elif echo "$smart_out" | grep -qi "FAILED"; then
            SMART_STATUS="FAILED"
            ISSUES+=("SMART: FAILED")
            printf '    %s✗%s SMART: FAILED — drive may be failing\n' "$RED" "$RESET"
        else
            SMART_STATUS="UNAVAILABLE"
            printf '    %s-%s SMART: unavailable\n' "$YELLOW" "$RESET"
        fi
    else
        # shellcheck disable=SC2034
        SMART_STATUS="NOT_INSTALLED"
        printf '    %s-%s SMART: smartctl not installed\n' "$YELLOW" "$RESET"
    fi

    # ── I/O errors in dmesg ──
    if dmesg_has_io_errors "$SEL_DEV"; then
        if ! $HAS_UAS_ISSUE; then  # Don't double-report if UAS already flagged
            ISSUES+=("I/O errors in dmesg")
            printf '    %s✗%s I/O errors in dmesg\n' "$RED" "$RESET"
        fi
    else
        printf '    %s✓%s No I/O errors in dmesg\n' "$GREEN" "$RESET"
    fi

    # If no issues at all
    if [[ ${#ISSUES[@]} -eq 0 ]]; then
        printf '    %s✓%s No issues found\n' "$GREEN" "$RESET"
    fi

    echo
    build_action_menu
    run_action_menu
}

# ═════════════════════════════════════════════════════════════════════════════
# ACTION MENU
# ═════════════════════════════════════════════════════════════════════════════

build_action_menu() {
    ACTIONS=()
    ACTION_FUNCS=()
    local has_recommended=false

    # UAS fix (USB+UAS only)
    if [[ "$SEL_TRANSPORT" == "USB (UAS)" && -n "$SEL_USB_IFACE" ]]; then
        ACTIONS+=("Fix UAS → usb-storage (switch driver now)")
        ACTION_FUNCS+=("action_fix_uas")
        has_recommended=true

        ACTIONS+=("Make UAS fix permanent (survives reboot)")
        ACTION_FUNCS+=("action_permanent_uas")
    fi

    # Filesystem repair (if any dirty)
    if $HAS_DIRTY_FS; then
        local repair_desc="Repair filesystems ("
        local first=true
        for (( i=0; i<${#DIRTY_PARTS[@]}; i++ )); do
            $first || repair_desc+=", "
            first=false
            local tool=""
            case "${DIRTY_FSTYPES[$i]}" in
                ntfs*)  tool="ntfsfix" ;;
                ext*)   tool="e2fsck" ;;
                exfat)  tool="fsck.exfat" ;;
                btrfs)  tool="btrfs check" ;;
                xfs)    tool="xfs_repair" ;;
                vfat*)  tool="fsck.vfat" ;;
            esac
            repair_desc+="$tool on ${DIRTY_PARTS[$i]}"
        done
        repair_desc+=")"
        ACTIONS+=("$repair_desc")
        ACTION_FUNCS+=("action_repair_fs")
        has_recommended=true
    fi

    # Mount partitions (if any unmounted)
    if $HAS_UNMOUNTED; then
        ACTIONS+=("Mount partitions")
        ACTION_FUNCS+=("action_mount")
        has_recommended=true
    fi

    # SMART details (always)
    ACTIONS+=("SMART health details")
    ACTION_FUNCS+=("action_smart")

    # dmesg errors (always)
    ACTIONS+=("Show dmesg errors")
    ACTION_FUNCS+=("action_dmesg")

    # Rescan drive (always)
    ACTIONS+=("Rescan drive")
    ACTION_FUNCS+=("action_rescan")

    # Run all recommended (if there are recommendations)
    if $has_recommended; then
        ACTIONS+=("Run all recommended fixes")
        ACTION_FUNCS+=("action_run_all")
    fi
}

run_action_menu() {
    while true; do
        printf '  %sActions:%s\n' "$BOLD" "$RESET"
        local i
        for (( i=0; i<${#ACTIONS[@]}; i++ )); do
            printf '  [%d] %s\n' "$((i+1))" "${ACTIONS[$i]}"
        done
        printf '  [0] Back to drive list\n\n'

        local choice
        printf '  Select action [0-%d]: ' "${#ACTIONS[@]}"
        prompt_read choice

        if [[ "$choice" == "0" ]]; then
            echo
            return
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ACTIONS[@]} )); then
            local idx=$((choice - 1))
            echo
            "${ACTION_FUNCS[$idx]}"
            echo

            # Re-diagnose after a fix to refresh state
            if [[ "${ACTION_FUNCS[$idx]}" == action_fix_uas || \
                  "${ACTION_FUNCS[$idx]}" == action_repair_fs || \
                  "${ACTION_FUNCS[$idx]}" == action_mount || \
                  "${ACTION_FUNCS[$idx]}" == action_rescan ]]; then
                # Refresh transport info after UAS fix
                if [[ "${ACTION_FUNCS[$idx]}" == "action_fix_uas" ]]; then
                    SEL_TRANSPORT=$(detect_transport "$SEL_DEV")
                    if [[ "$SEL_TRANSPORT" == "USB" ]] && is_uas_device "$SEL_DEV"; then
                        SEL_TRANSPORT="USB (UAS)"
                    fi
                fi
                refresh_diagnosis
            fi
        else
            warn "Invalid selection."
        fi
    done
}

refresh_diagnosis() {
    # Re-check issues without full banner reprint
    ISSUES=()
    DIRTY_PARTS=()
    DIRTY_FSTYPES=()
    UNMOUNTED_PARTS=()
    UNMOUNTED_FSTYPES=()
    HAS_UAS_ISSUE=false
    HAS_DIRTY_FS=false
    HAS_UNMOUNTED=false

    if [[ "$SEL_TRANSPORT" == "USB (UAS)" ]] && dmesg_has_uas_errors "$SEL_DEV"; then
        HAS_UAS_ISSUE=true
    fi

    while IFS= read -r pline; do
        local pname pfs pmnt
        pname=$(echo "$pline" | awk '{print $1}')
        pfs=$(echo "$pline" | awk '{print $2}')
        pmnt=$(echo "$pline" | awk '{print $5}')
        [[ -z "$pfs" || "$pfs" == "swap" ]] && continue

        local dirty=false
        if [[ "$pfs" == ntfs* ]] && is_ntfs_dirty "/dev/$pname"; then
            dirty=true
        elif [[ "$pfs" == ext* ]] && is_ext_dirty "/dev/$pname"; then
            dirty=true
        fi

        if $dirty; then
            HAS_DIRTY_FS=true
            DIRTY_PARTS+=("$pname")
            DIRTY_FSTYPES+=("$pfs")
        fi

        if [[ -z "$pmnt" || "$pmnt" == "-" ]]; then
            HAS_UNMOUNTED=true
            UNMOUNTED_PARTS+=("$pname")
            UNMOUNTED_FSTYPES+=("$pfs")
        fi
    done < <(get_partitions "$SEL_DEV")

    build_action_menu
}

# ═════════════════════════════════════════════════════════════════════════════
# ACTION: FIX UAS → usb-storage
# ═════════════════════════════════════════════════════════════════════════════
action_fix_uas() {
    banner "Fix UAS → usb-storage"

    [[ -z "$SEL_USB_IFACE" || -z "$SEL_USB_VIDPID" ]] && {
        err "No USB interface info available."
        return 1
    }

    local vidpid="$SEL_USB_VIDPID"

    # Detect quirk flags from dmesg
    local quirk_flags="u"
    local dmesg_out
    dmesg_out=$(dmesg 2>/dev/null | grep -i "$SEL_DEV" || true)
    if echo "$dmesg_out" | grep -qi "sense key"; then
        quirk_flags+="s"
    fi
    if echo "$dmesg_out" | grep -qi "reset"; then
        quirk_flags+="r"
    fi
    if echo "$dmesg_out" | grep -qi "capacity\|last sector"; then
        quirk_flags+="c"
    fi

    # 1. Push quirk into running usb_storage module
    local qfile="/sys/module/usb_storage/parameters/quirks"
    if [[ -f "$qfile" ]]; then
        local cur
        cur=$(cat "$qfile")
        if [[ "$cur" != *"$vidpid"* ]]; then
            local new="${cur:+${cur},}${vidpid}:${quirk_flags}"
            if echo "$new" > "$qfile"; then
                ok "Runtime quirk applied: $vidpid:$quirk_flags → usb-storage"
            else
                warn "Could not write to $qfile"
            fi
        else
            ok "Runtime quirk already active for $vidpid"
        fi
    else
        warn "usb_storage not loaded — quirk will activate on next module load."
    fi

    # 2. Unbind from UAS
    local uas_unbind="/sys/bus/usb/drivers/uas/unbind"
    if [[ -f "$uas_unbind" ]]; then
        if echo -n "$SEL_USB_IFACE" > "$uas_unbind" 2>/dev/null; then
            ok "Unbound $SEL_USB_IFACE from UAS driver"
        else
            warn "Unbind failed (device may have already disconnected)"
        fi
    fi

    # 3. Bind to usb-storage
    sleep 1
    local us_bind="/sys/bus/usb/drivers/usb-storage/bind"
    if [[ -f "$us_bind" ]]; then
        if echo -n "$SEL_USB_IFACE" > "$us_bind" 2>/dev/null; then
            ok "Bound $SEL_USB_IFACE to usb-storage driver"
        else
            warn "Direct bind failed — triggering USB re-enumeration..."
            local devpath
            devpath="/sys/bus/usb/devices/$(iface_to_dev "$SEL_USB_IFACE")/authorized"
            if [[ -f "$devpath" ]]; then
                echo 0 > "$devpath"; sleep 1; echo 1 > "$devpath"
                ok "USB device re-enumerated"
            fi
        fi
    fi

    # 4. Wait for block device with retry (max 3 attempts)
    local attempt
    for attempt in 1 2 3; do
        log "Waiting for block device (attempt $attempt/3, up to 15s)..."
        local t=0
        while (( t < 15 )); do
            # Check if the device exists and is readable
            if [[ -b "/dev/$SEL_DEV" ]]; then
                if dd if="/dev/$SEL_DEV" of=/dev/null bs=512 count=1 &>/dev/null; then
                    ok "Block device ready: /dev/$SEL_DEV"
                    SEL_USB_DRIVER="usb-storage"
                    return 0
                fi
            fi
            # Also check if it re-enumerated as a different device
            local new_iface
            new_iface=$(find_usb_iface_for_block "$SEL_DEV")
            if [[ -n "$new_iface" ]]; then
                SEL_USB_IFACE="$new_iface"
                if [[ -b "/dev/$SEL_DEV" ]]; then
                    ok "Block device ready: /dev/$SEL_DEV"
                    # shellcheck disable=SC2034
                    SEL_USB_DRIVER="usb-storage"
                    return 0
                fi
            fi
            sleep 1; ((t++)) || true
        done

        if (( attempt < 3 )); then
            warn "Device not ready yet."
            printf '  Replug the drive now, then press Enter to retry (Ctrl+C to abort): '
            local _discard
            prompt_read _discard
        fi
    done

    err "Block device did not appear after 3 attempts."
    warn "The drive may need a physical replug and re-run of this tool."
    return 1
}

# ═════════════════════════════════════════════════════════════════════════════
# ACTION: MAKE UAS FIX PERMANENT
# ═════════════════════════════════════════════════════════════════════════════
action_permanent_uas() {
    banner "Make UAS Fix Permanent"

    [[ -z "$SEL_USB_VIDPID" ]] && {
        err "No USB VID:PID available."
        return 1
    }

    local vidpid="$SEL_USB_VIDPID"
    local conf="/etc/modprobe.d/usb-storage-quirks.conf"

    # Backup if exists
    if [[ -f "$conf" ]]; then
        make_tmpdir
        cp "$conf" "$TMPDIR_4KN/usb-storage-quirks.conf.bak"
        ok "Backed up $conf"
    fi

    # Merge quirk idempotently
    if [[ -f "$conf" ]]; then
        local existing
        existing=$(grep -E "^options usb-storage quirks=" "$conf" | sed 's/options usb-storage quirks=//' | tail -1)
        if [[ "$existing" == *"$vidpid"* ]]; then
            ok "Permanent quirk already in $conf"
        else
            local merged="${existing:+${existing},}${vidpid}:u"
            if grep -q "^options usb-storage quirks=" "$conf"; then
                sed -i "s|^options usb-storage quirks=.*|options usb-storage quirks=${merged}|" "$conf"
            else
                echo "options usb-storage quirks=${merged}" >> "$conf"
            fi
            ok "Updated $conf → quirks=${merged}"
        fi
    else
        cat > "$conf" <<EOF
# Generated by 4kn-fix.sh
# Forces usb-storage (BOT) instead of UAS for problematic drives.
# 'u' flag: UAS device forced to use Bulk-Only Transport.
options usb-storage quirks=${vidpid}:u
EOF
        ok "Created $conf"
    fi

    # Rebuild initramfs
    log "Rebuilding initramfs..."
    if   command -v mkinitcpio      &>/dev/null; then mkinitcpio -P         && ok "initramfs rebuilt (mkinitcpio)"
    elif command -v dracut          &>/dev/null; then dracut --force         && ok "initramfs rebuilt (dracut)"
    elif command -v update-initramfs &>/dev/null; then update-initramfs -u   && ok "initramfs rebuilt (update-initramfs)"
    else warn "No initramfs tool found. Rebuild manually if needed."
    fi

    # Print kernel cmdline alternative
    echo
    log "Alternative: add to kernel cmdline:"
    printf '    usb-storage.quirks=%s:u\n' "$vidpid"
}

# ═════════════════════════════════════════════════════════════════════════════
# ACTION: REPAIR FILESYSTEMS
# ═════════════════════════════════════════════════════════════════════════════
action_repair_fs() {
    banner "Repair Filesystems"

    if [[ ${#DIRTY_PARTS[@]} -eq 0 ]]; then
        ok "No dirty filesystems found."
        return 0
    fi

    local i
    for (( i=0; i<${#DIRTY_PARTS[@]}; i++ )); do
        local part="${DIRTY_PARTS[$i]}"
        local fs="${DIRTY_FSTYPES[$i]}"
        local pdev="/dev/$part"

        [[ -b "$pdev" ]] || continue

        # Check if mounted
        local pmnt
        pmnt=$(lsblk -dno MOUNTPOINT "$pdev" 2>/dev/null | xargs)
        if [[ -n "$pmnt" && "$pmnt" != "-" ]]; then
            warn "$pdev is mounted at $pmnt — must unmount before repair."
            printf '  Unmount %s? [y/N]: ' "$pdev"
            local yn
            prompt_read yn
            if [[ "${yn,,}" == "y" || "${yn,,}" == "yes" ]]; then
                if umount "$pdev" 2>/dev/null; then
                    ok "Unmounted $pdev"
                else
                    err "Failed to unmount $pdev — skipping."
                    continue
                fi
            else
                log "Skipping $pdev."
                continue
            fi
        fi

        printf '  Repair %s (%s)? [Y/n]: ' "$pdev" "$fs"
        local yn
        prompt_read yn
        if [[ "${yn,,}" == "n" || "${yn,,}" == "no" ]]; then
            log "Skipping $pdev."
            continue
        fi

        case "$fs" in
            ntfs*)
                if ! ensure_cmd ntfsfix ntfs-3g ntfs-3g ntfsprogs ntfsprogs ntfs-3g sys-fs/ntfs3g ntfs-3g ntfs-3g-progs; then
                    continue
                fi
                log "Running ntfsfix -d $pdev (clear dirty flag)..."
                ntfsfix -d "$pdev" && ok "$pdev: dirty flag cleared" || warn "$pdev: ntfsfix -d had issues"
                log "Running ntfsfix $pdev (repair)..."
                ntfsfix "$pdev" && ok "$pdev: repaired" || warn "$pdev: ntfsfix reported issues — run chkdsk from Windows for full repair"
                ;;
            ext*)
                if ! ensure_cmd e2fsck e2fsprogs e2fsprogs e2fsprogs e2fsprogs e2fsprogs sys-fs/e2fsprogs e2fsprogs e2fsprogs; then
                    continue
                fi
                log "Running e2fsck -p $pdev (auto-fix safe errors)..."
                e2fsck -p "$pdev"
                local rc=$?
                if (( rc == 0 )); then
                    ok "$pdev: clean"
                elif (( rc == 1 )); then
                    ok "$pdev: errors corrected"
                elif (( rc == 2 )); then
                    warn "$pdev: errors corrected, reboot recommended"
                else
                    warn "$pdev: e2fsck exited with code $rc — manual intervention may be needed"
                fi
                ;;
            exfat)
                if ensure_cmd fsck.exfat exfatprogs exfatprogs exfatprogs exfatprogs exfatprogs "" exfatprogs exfatprogs; then
                    log "Running fsck.exfat $pdev..."
                    fsck.exfat "$pdev" && ok "$pdev: clean" || warn "$pdev: fsck.exfat reported issues"
                else
                    warn "fsck.exfat not available — skipping $pdev"
                fi
                ;;
            btrfs)
                log "Running btrfs check $pdev (read-only)..."
                if btrfs check "$pdev" 2>&1; then
                    ok "$pdev: clean"
                else
                    warn "$pdev: btrfs check found issues."
                    printf '  Run btrfs check --repair? This is %sDESTRUCTIVE%s if it fails. [y/N]: ' "$RED" "$RESET"
                    local yn2
                    prompt_read yn2
                    if [[ "${yn2,,}" == "y" ]]; then
                        btrfs check --repair "$pdev" && ok "$pdev: repaired" || err "$pdev: repair failed"
                    fi
                fi
                ;;
            xfs)
                if ! ensure_cmd xfs_repair xfsprogs xfsprogs xfsprogs xfsprogs xfsprogs sys-fs/xfsprogs xfsprogs xfsprogs; then
                    continue
                fi
                log "Running xfs_repair -n $pdev (check only)..."
                if xfs_repair -n "$pdev" 2>&1; then
                    ok "$pdev: clean"
                else
                    warn "$pdev: xfs_repair found issues."
                    printf '  Run xfs_repair (may need -L for dirty log)? [y/N]: '
                    local yn2
                    prompt_read yn2
                    if [[ "${yn2,,}" == "y" ]]; then
                        xfs_repair "$pdev" && ok "$pdev: repaired" || {
                            warn "Trying xfs_repair -L (force log zeroing)..."
                            xfs_repair -L "$pdev" && ok "$pdev: repaired with -L" || err "$pdev: repair failed"
                        }
                    fi
                fi
                ;;
            vfat*|fat*)
                if ! ensure_cmd fsck.vfat dosfstools dosfstools dosfstools dosfstools dosfstools sys-fs/dosfstools dosfstools dosfstools; then
                    continue
                fi
                log "Running fsck.vfat -a $pdev..."
                fsck.vfat -a "$pdev" && ok "$pdev: clean" || warn "$pdev: fsck.vfat reported issues"
                ;;
            *)
                warn "$pdev: no repair tool for filesystem '$fs'"
                ;;
        esac
    done
}

# ═════════════════════════════════════════════════════════════════════════════
# ACTION: MOUNT PARTITIONS
# ═════════════════════════════════════════════════════════════════════════════
action_mount() {
    banner "Mount Partitions"

    if [[ ${#UNMOUNTED_PARTS[@]} -eq 0 ]]; then
        ok "No unmounted partitions found."
        return 0
    fi

    local media_base="/run/media/$REAL_USER"
    mkdir -p "$media_base"

    local i
    for (( i=0; i<${#UNMOUNTED_PARTS[@]}; i++ )); do
        local part="${UNMOUNTED_PARTS[$i]}"
        local fs="${UNMOUNTED_FSTYPES[$i]}"
        local pdev="/dev/$part"

        [[ -b "$pdev" ]] || continue

        # Recheck — might have been mounted by a previous iteration
        local pmnt
        pmnt=$(lsblk -dno MOUNTPOINT "$pdev" 2>/dev/null | xargs)
        if [[ -n "$pmnt" && "$pmnt" != "-" ]]; then
            ok "$pdev already mounted at $pmnt"
            continue
        fi

        local label
        label=$(lsblk -dno LABEL "$pdev" 2>/dev/null | xargs)
        local mntname="${label:-$part}"
        local mntpoint="$media_base/$mntname"
        mkdir -p "$mntpoint"

        local mounted=false

        case "$fs" in
            ntfs*)
                # Try kernel ntfs3 first, fall back to ntfs-3g
                if mount -t ntfs3 -o "force,uid=$REAL_UID,gid=$REAL_GID,noatime" \
                        "$pdev" "$mntpoint" 2>/dev/null; then
                    mounted=true
                elif command -v ntfs-3g &>/dev/null && \
                     ntfs-3g -o "force,uid=$REAL_UID,gid=$REAL_GID,noatime" \
                        "$pdev" "$mntpoint" 2>/dev/null; then
                    mounted=true
                elif ensure_cmd ntfs-3g ntfs-3g ntfs-3g ntfsprogs ntfsprogs ntfs-3g sys-fs/ntfs3g ntfs-3g ntfs-3g-progs 2>/dev/null; then
                    ntfs-3g -o "force,uid=$REAL_UID,gid=$REAL_GID,noatime" \
                        "$pdev" "$mntpoint" 2>/dev/null && mounted=true
                fi
                ;;
            exfat)
                # Try kernel exfat first
                if mount -t exfat -o "uid=$REAL_UID,gid=$REAL_GID,noatime" \
                        "$pdev" "$mntpoint" 2>/dev/null; then
                    mounted=true
                elif command -v mount.exfat-fuse &>/dev/null && \
                     mount.exfat-fuse -o "uid=$REAL_UID,gid=$REAL_GID,noatime" \
                        "$pdev" "$mntpoint" 2>/dev/null; then
                    mounted=true
                fi
                ;;
            vfat*|fat*)
                mount -t vfat -o "uid=$REAL_UID,gid=$REAL_GID,noatime" \
                    "$pdev" "$mntpoint" 2>/dev/null && mounted=true
                ;;
            *)
                mount -o noatime "$pdev" "$mntpoint" 2>/dev/null && mounted=true
                ;;
        esac

        if $mounted; then
            ok "Mounted $pdev → $mntpoint"
        else
            # Last resort: udisksctl
            if command -v udisksctl &>/dev/null; then
                local ud_out
                if ud_out=$(udisksctl mount -b "$pdev" 2>&1); then
                    rmdir "$mntpoint" 2>/dev/null || true
                    ok "$pdev mounted via udisksctl ($ud_out)"
                else
                    rmdir "$mntpoint" 2>/dev/null || true
                    warn "Could not mount $pdev — try manually: mount $pdev /mnt"
                fi
            else
                rmdir "$mntpoint" 2>/dev/null || true
                warn "Could not mount $pdev — try manually: mount $pdev /mnt"
            fi
        fi
    done
}

# ═════════════════════════════════════════════════════════════════════════════
# ACTION: SMART HEALTH
# ═════════════════════════════════════════════════════════════════════════════
action_smart() {
    banner "SMART Health — /dev/$SEL_DEV"

    if ! ensure_cmd smartctl smartmontools smartmontools smartmontools smartmontools smartmontools sys-apps/smartmontools smartmontools smartmontools; then
        return 1
    fi

    local smart_args=""
    if [[ "$SEL_TRANSPORT" == USB* ]]; then
        smart_args="-d sat"
    fi

    # Overall health
    log "Overall health:"
    # shellcheck disable=SC2086
    smartctl -H $smart_args "/dev/$SEL_DEV" 2>&1 | grep -iE "result|status|health" || true

    echo

    # Key attributes
    log "Key attributes:"
    local attrs_out
    # shellcheck disable=SC2086
    attrs_out=$(smartctl -A $smart_args "/dev/$SEL_DEV" 2>&1) || true

    if [[ -n "$attrs_out" ]]; then
        # Show key fields
        echo "$attrs_out" | grep -iE "Reallocated|CRC|Temperature|Power_On_Hours|Wear_Leveling|Media_Wearout|Percentage_Used|Available_Spare" || true

        # If NVMe, show different info
        if [[ "$SEL_DEV" == nvme* ]]; then
            echo
            # shellcheck disable=SC2086
            smartctl -a $smart_args "/dev/$SEL_DEV" 2>&1 | grep -iE "Percentage Used|Available Spare|Temperature|Power On Hours|Data Units" || true
        fi
    fi

    if [[ "$SEL_TRANSPORT" == USB* ]]; then
        echo
        log "Note: SMART over USB uses SAT passthrough — some drives don't support it."
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# ACTION: SHOW DMESG ERRORS
# ═════════════════════════════════════════════════════════════════════════════
action_dmesg() {
    banner "dmesg errors — /dev/$SEL_DEV"

    local lines
    lines=$(dmesg 2>/dev/null | grep -i "$SEL_DEV" | tail -30)

    if [[ -z "$lines" ]]; then
        ok "No dmesg entries for $SEL_DEV"
        return 0
    fi

    while IFS= read -r line; do
        if echo "$line" | grep -qiE "err|fail|reset|abort|offline|timeout|I/O"; then
            printf '  %s%s%s\n' "$RED" "$line" "$RESET"
        else
            printf '  %s\n' "$line"
        fi
    done <<< "$lines"
}

# ═════════════════════════════════════════════════════════════════════════════
# ACTION: RESCAN DRIVE
# ═════════════════════════════════════════════════════════════════════════════
action_rescan() {
    banner "Rescan Drive"

    if [[ -f "/sys/block/$SEL_DEV/device/rescan" ]]; then
        echo 1 > "/sys/block/$SEL_DEV/device/rescan" 2>/dev/null
        ok "Triggered rescan on /dev/$SEL_DEV"
    fi

    # Re-read partition table
    if command -v partprobe &>/dev/null; then
        partprobe "/dev/$SEL_DEV" 2>/dev/null && ok "Partition table re-read (partprobe)"
    elif command -v blockdev &>/dev/null; then
        blockdev --rereadpt "/dev/$SEL_DEV" 2>/dev/null && ok "Partition table re-read (blockdev)"
    fi

    sleep 2
    ok "Rescan complete."
}

# ═════════════════════════════════════════════════════════════════════════════
# ACTION: RUN ALL RECOMMENDED
# ═════════════════════════════════════════════════════════════════════════════
action_run_all() {
    banner "Run All Recommended Fixes"

    local steps=()

    if [[ "$SEL_TRANSPORT" == "USB (UAS)" && -n "$SEL_USB_IFACE" ]]; then
        steps+=("UAS driver fix")
    fi
    if $HAS_DIRTY_FS; then
        steps+=("Filesystem repair")
    fi
    if $HAS_UNMOUNTED; then
        steps+=("Mount partitions")
    fi

    if [[ ${#steps[@]} -eq 0 ]]; then
        ok "No recommended fixes needed."
        return 0
    fi

    log "Will run:"
    local s
    for s in "${steps[@]}"; do
        printf '    • %s\n' "$s"
    done
    echo
    printf '  Proceed? [Y/n]: '
    local yn
    prompt_read yn
    if [[ "${yn,,}" == "n" || "${yn,,}" == "no" ]]; then
        log "Cancelled."
        return 0
    fi

    echo

    # 1. UAS fix
    if [[ "$SEL_TRANSPORT" == "USB (UAS)" && -n "$SEL_USB_IFACE" ]]; then
        if action_fix_uas; then
            echo
            printf '  Also make UAS fix permanent? [Y/n]: '
            prompt_read yn
            if [[ "${yn,,}" != "n" && "${yn,,}" != "no" ]]; then
                action_permanent_uas
            fi
        fi
        echo
        SEL_TRANSPORT=$(detect_transport "$SEL_DEV")
        if [[ "$SEL_TRANSPORT" == "USB" ]] && is_uas_device "$SEL_DEV"; then
            SEL_TRANSPORT="USB (UAS)"
        fi
    fi

    # 2. Filesystem repair
    if $HAS_DIRTY_FS; then
        action_repair_fs
        echo
    fi

    # 3. Mount
    if $HAS_UNMOUNTED; then
        # Refresh unmounted list after repair
        UNMOUNTED_PARTS=()
        UNMOUNTED_FSTYPES=()
        HAS_UNMOUNTED=false
        while IFS= read -r pline; do
            local pname pfs pmnt
            pname=$(echo "$pline" | awk '{print $1}')
            pfs=$(echo "$pline" | awk '{print $2}')
            pmnt=$(echo "$pline" | awk '{print $5}')
            [[ -z "$pfs" || "$pfs" == "swap" ]] && continue
            if [[ -z "$pmnt" || "$pmnt" == "-" ]]; then
                HAS_UNMOUNTED=true
                UNMOUNTED_PARTS+=("$pname")
                UNMOUNTED_FSTYPES+=("$pfs")
            fi
        done < <(get_partitions "$SEL_DEV")

        if $HAS_UNMOUNTED; then
            action_mount
        fi
    fi

    echo
    ok "All recommended fixes completed."
}

# ═════════════════════════════════════════════════════════════════════════════
# MAIN
# ═════════════════════════════════════════════════════════════════════════════
main() {
    parse_args "$@"
    setup_colors

    # Re-parse in case --no-color was set
    if [[ -n "${NO_COLOR:-}" ]]; then
        setup_colors
    fi

    printf '\n  %s%s4KN-Fix — Linux Drive Toolkit%s  v%s\n\n' "$BOLD" "$CYAN" "$RESET" "$VERSION"

    ensure_root "$@"
    detect_real_user
    check_container
    detect_distro

    select_drive
}

main "$@"
