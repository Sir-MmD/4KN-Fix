#!/usr/bin/env bash
# uas-fix.sh — Fix 4KN / UAS USB drive recognition issues
# Supports: Arch Linux · Debian/Ubuntu · Fedora · AlmaLinux/RHEL
# Usage: sudo bash uas-fix.sh

# ─── Strict mode (no -e; we handle errors manually for interactive use) ────────
set -uo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m';  BOLD='\033[1m'; RESET='\033[0m'

log()    { echo -e "${BLUE}[*]${RESET} $*"; }
ok()     { echo -e "${GREEN}[✓]${RESET} $*"; }
warn()   { echo -e "${YELLOW}[!]${RESET} $*"; }
err()    { echo -e "${RED}[✗]${RESET} $*" >&2; }
die()    { err "$*"; exit 1; }
banner() { echo -e "\n${BOLD}${CYAN}─── $* ───${RESET}\n"; }
ask()    { echo -e -n "${YELLOW}[?]${RESET} $* "; }

# ─── Root escalation ──────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    if command -v sudo &>/dev/null; then
        exec sudo bash "$0" "$@"
    else
        die "Run as root or install sudo."
    fi
fi

# Real user (the one who invoked sudo, not root)
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
REAL_UID=$(id -u "$REAL_USER" 2>/dev/null || echo 0)
REAL_GID=$(id -g "$REAL_USER" 2>/dev/null || echo 0)

# ═════════════════════════════════════════════════════════════════════════════
# DISTRO DETECTION
# ═════════════════════════════════════════════════════════════════════════════
detect_distro() {
    [[ -f /etc/os-release ]] || die "Cannot detect distro: /etc/os-release missing."
    # shellcheck source=/dev/null
    source /etc/os-release
    local id="${ID,,}" like="${ID_LIKE,,}"

    if   [[ "$id" == "arch"     || "$like" == *"arch"*   ]]; then DISTRO_FAMILY="arch";   PKG_MGR="pacman"
    elif [[ "$id" == "debian"   || "$id" == "ubuntu"
         || "$id" == "linuxmint"|| "$like" == *"debian"* ]]; then DISTRO_FAMILY="debian";  PKG_MGR="apt"
    elif [[ "$id" == "fedora"   || "$like" == *"fedora"* ]]; then DISTRO_FAMILY="fedora";  PKG_MGR="dnf"
    elif [[ "$id" == "almalinux"|| "$id" == "rocky"
         || "$id" == "rhel"     || "$id" == "centos"
         || "$like" == *"rhel"* ]]; then                          DISTRO_FAMILY="rhel";    PKG_MGR="dnf"
    else
        warn "Unknown distro '$id'; will try to continue without auto-install."
        DISTRO_FAMILY="unknown"; PKG_MGR=""
    fi
    ok "Distro: ${PRETTY_NAME:-$id}  (family: $DISTRO_FAMILY)"
}

# ═════════════════════════════════════════════════════════════════════════════
# PACKAGE INSTALLATION
# ═════════════════════════════════════════════════════════════════════════════
install_deps() {
    banner "Checking Dependencies"

    local need_usbutils=false need_ntfsfix=false need_util=false

    command -v lsusb   &>/dev/null || need_usbutils=true
    command -v ntfsfix &>/dev/null || need_ntfsfix=true
    command -v lsblk   &>/dev/null || need_util=true

    if ! $need_usbutils && ! $need_ntfsfix && ! $need_util; then
        ok "All dependencies already installed."; return 0
    fi

    log "Installing missing packages..."

    case "$DISTRO_FAMILY" in
    arch)
        local pkgs=()
        $need_usbutils && pkgs+=(usbutils)
        $need_ntfsfix  && pkgs+=(ntfs-3g)
        $need_util     && pkgs+=(util-linux)
        [[ ${#pkgs[@]} -gt 0 ]] && pacman -Sy --noconfirm --needed "${pkgs[@]}"
        ;;
    debian)
        local pkgs=()
        $need_usbutils && pkgs+=(usbutils)
        $need_ntfsfix  && pkgs+=(ntfs-3g)
        $need_util     && pkgs+=(util-linux)
        [[ ${#pkgs[@]} -gt 0 ]] && { apt-get update -qq; apt-get install -y "${pkgs[@]}"; }
        ;;
    fedora)
        local pkgs=()
        $need_usbutils && pkgs+=(usbutils)
        $need_ntfsfix  && pkgs+=(ntfsprogs)
        $need_util     && pkgs+=(util-linux)
        [[ ${#pkgs[@]} -gt 0 ]] && dnf install -y "${pkgs[@]}"
        ;;
    rhel)
        # Enable EPEL for ntfsprogs
        if $need_ntfsfix && ! rpm -q epel-release &>/dev/null; then
            log "Enabling EPEL repository..."
            dnf install -y epel-release
        fi
        local pkgs=()
        $need_usbutils && pkgs+=(usbutils)
        $need_ntfsfix  && pkgs+=(ntfsprogs)
        $need_util     && pkgs+=(util-linux)
        [[ ${#pkgs[@]} -gt 0 ]] && dnf install -y "${pkgs[@]}"
        ;;
    *)
        warn "Auto-install not supported. Please install manually: usbutils ntfs-3g util-linux"
        ;;
    esac
    ok "Dependencies ready."
}

# ═════════════════════════════════════════════════════════════════════════════
# SYSFS HELPERS
# ═════════════════════════════════════════════════════════════════════════════

# List USB interface IDs currently bound to a driver
list_driver_ifaces() {
    local drv_path="/sys/bus/usb/drivers/$1"
    [[ -d "$drv_path" ]] || return 0
    for entry in "$drv_path"/*/; do
        local name; name=$(basename "$entry")
        [[ "$name" =~ ^(bind|unbind|module|new_id|remove_id|uevent)$ ]] && continue
        [[ -d "$entry" ]] && echo "$name"
    done
}

# Get USB device sysfs base dir from an interface ID (e.g. "4-4:1.0" → "4-4")
iface_to_dev() { echo "${1%:*}"; }

sysfs_read() { cat "$1" 2>/dev/null || echo ""; }

# Read VID, PID, product name for an interface
usb_info() {
    local iface="$1" dev
    dev=$(iface_to_dev "$iface")
    local base="/sys/bus/usb/devices/$dev"
    local vid pid mfr prod
    vid=$(sysfs_read "$base/idVendor")
    pid=$(sysfs_read "$base/idProduct")
    mfr=$(sysfs_read "$base/manufacturer")
    prod=$(sysfs_read "$base/product")
    printf '%s:%s|%s %s' "$vid" "$pid" "$mfr" "$prod"
}

# Find the /dev/sdX name for a USB interface bound to uas or usb-storage
block_dev_for_iface() {
    local iface="$1"
    local found=""
    for drv in uas usb-storage; do
        local base="/sys/bus/usb/drivers/$drv/$iface"
        [[ -d "$base" ]] || continue
        # Walk: host* → target* → <lun> → block → sdX
        local block_dir
        block_dir=$(find "$base" -maxdepth 5 -name "block" -type d 2>/dev/null | head -1)
        [[ -z "$block_dir" ]] && continue
        found=$(ls "$block_dir/" 2>/dev/null | head -1)
        [[ -n "$found" ]] && break
    done
    echo "$found"
}

# True if dmesg shows UAS errors for a block device name
dmesg_has_uas_errors() {
    local blk="$1"
    dmesg 2>/dev/null | grep -qE "\[${blk}\].*(err|FAILED|offline|cmplt err)" 2>/dev/null
}

# ═════════════════════════════════════════════════════════════════════════════
# DEVICE SELECTION
# ═════════════════════════════════════════════════════════════════════════════

# Globals set by select_device()
SEL_VID="" SEL_PID="" SEL_NAME="" SEL_IFACE="" SEL_BLOCK="" SEL_DRIVER=""

select_device() {
    banner "Scanning for USB Storage Devices"

    # Collect interfaces from both UAS and usb-storage drivers
    declare -A _VID _PID _NAME _IFACE _BLOCK _DRIVER
    local i=1

    for drv in uas usb-storage; do
        mapfile -t DRV_IFACES < <(list_driver_ifaces "$drv")
        for iface in "${DRV_IFACES[@]}"; do
            local info; info=$(usb_info "$iface")
            local vidpid="${info%%|*}"
            local name="${info##*|}"
            local vid="${vidpid%%:*}" pid="${vidpid##*:}"
            local blk; blk=$(block_dev_for_iface "$iface")

            _VID[$i]="$vid"; _PID[$i]="$pid"; _NAME[$i]="$name"
            _IFACE[$i]="$iface"; _BLOCK[$i]="${blk:-}"; _DRIVER[$i]="$drv"
            ((i++)) || true
        done
    done

    if (( i == 1 )); then
        warn "No USB storage devices found."
        echo
        echo "  Possible reasons:"
        echo "  • Drive is not plugged in"
        echo "  • Drive disconnected due to errors — replug and re-run"
        echo
        exit 0
    fi

    echo -e "${BOLD}Detected USB storage device(s):${RESET}\n"

    local n
    for (( n=1; n<i; n++ )); do
        local vid="${_VID[$n]}" pid="${_PID[$n]}" name="${_NAME[$n]}"
        local iface="${_IFACE[$n]}" blk="${_BLOCK[$n]}" drv="${_DRIVER[$n]}"

        # Status badge
        local badge=""
        if [[ "$drv" == "uas" ]]; then
            badge=" ${YELLOW}[UAS]${RESET}"
            if [[ -n "$blk" ]] && dmesg_has_uas_errors "$blk"; then
                badge=" ${RED}[UAS errors]${RESET}"
            fi
        else
            # Check if any partitions are unmounted
            local has_unmounted=false
            if [[ -n "$blk" && -b "/dev/$blk" ]]; then
                while IFS= read -r pline; do
                    local pname pfs pmnt
                    pname=$(echo "$pline" | awk '{print $1}')
                    pfs=$(echo "$pline" | awk '{print $2}')
                    pmnt=$(echo "$pline" | awk '{print $3}')
                    if [[ -n "$pfs" && "$pfs" != "swap" && ( -z "$pmnt" || "$pmnt" == "-" ) ]]; then
                        has_unmounted=true; break
                    fi
                done < <(lsblk -rno NAME,FSTYPE,MOUNTPOINT "/dev/$blk" 2>/dev/null | tail -n +2)
            fi
            if $has_unmounted; then
                badge=" ${YELLOW}[not mounted]${RESET}"
            else
                badge=" ${GREEN}[ok]${RESET}"
            fi
        fi

        echo -e "  ${BOLD}[$n]${RESET} ${CYAN}${name:-Unknown device}${RESET} (${vid}:${pid})${badge}"
        echo -e "       Interface : $iface   Driver: $drv"

        if [[ -n "$blk" && -b "/dev/$blk" ]]; then
            local size phy log
            size=$(lsblk -dno SIZE "/dev/$blk" 2>/dev/null || echo "?")
            phy=$(lsblk  -dno PHY-SEC "/dev/$blk" 2>/dev/null || echo "?")
            log=$(lsblk  -dno LOG-SEC "/dev/$blk" 2>/dev/null || echo "?")
            echo -e "       Block dev : ${GREEN}/dev/$blk${RESET}  size=${size}  PHY-SEC=${phy}  LOG-SEC=${log}"
            if [[ "$phy" == "4096" && "$log" == "4096" ]]; then
                echo -e "       Type      : ${YELLOW}4KN (native 4K sectors)${RESET}"
            elif [[ "$phy" == "4096" ]]; then
                echo -e "       Type      : 512e (4K physical, 512 logical emulation)"
            fi
        else
            echo -e "       Block dev : ${YELLOW}not visible${RESET} (init failed)"
        fi
        echo
    done

    echo -e "  ${BOLD}[0]${RESET} Exit\n"

    local choice
    while true; do
        ask "Select device to fix [0-$((i-1))]:"; read -r choice
        if [[ "$choice" == "0" ]]; then log "Exiting."; exit 0; fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < i )); then
            SEL_VID="${_VID[$choice]}"   SEL_PID="${_PID[$choice]}"
            SEL_NAME="${_NAME[$choice]}" SEL_IFACE="${_IFACE[$choice]}"
            SEL_BLOCK="${_BLOCK[$choice]}" SEL_DRIVER="${_DRIVER[$choice]}"
            break
        fi
        warn "Invalid selection."
    done

    echo
    log "Selected: ${SEL_NAME} (${SEL_VID}:${SEL_PID})  driver: ${SEL_DRIVER}"
}

# ═════════════════════════════════════════════════════════════════════════════
# RUNTIME FIX
# ═════════════════════════════════════════════════════════════════════════════
apply_runtime_fix() {
    banner "Applying Runtime Fix"

    local vidpid="${SEL_VID}:${SEL_PID}"

    # 1. Push quirk into running usb_storage module
    local qfile="/sys/module/usb_storage/parameters/quirks"
    if [[ -f "$qfile" ]]; then
        local cur; cur=$(cat "$qfile")
        if [[ "$cur" != *"$vidpid"* ]]; then
            # Append to existing quirks (comma-separated)
            local new="${cur:+${cur},}${vidpid}:u"
            echo "$new" > "$qfile" \
                && ok "Runtime quirk applied: $vidpid → usb-storage (BOT)" \
                || warn "Could not write to $qfile"
        else
            ok "Runtime quirk already active for $vidpid"
        fi
    else
        warn "usb_storage not loaded — quirk will activate on next module load."
    fi

    # 2. Unbind from UAS
    local uas_unbind="/sys/bus/usb/drivers/uas/unbind"
    if [[ -f "$uas_unbind" ]]; then
        if echo -n "$SEL_IFACE" > "$uas_unbind" 2>/dev/null; then
            ok "Unbound $SEL_IFACE from UAS driver"
        else
            warn "Unbind failed (device may have already disconnected)"
        fi
    fi

    # 3. Bind to usb-storage
    local us_bind="/sys/bus/usb/drivers/usb-storage/bind"
    sleep 1
    if [[ -f "$us_bind" ]]; then
        if echo -n "$SEL_IFACE" > "$us_bind" 2>/dev/null; then
            ok "Bound $SEL_IFACE to usb-storage driver"
        else
            warn "Direct bind failed — triggering USB re-enumeration..."
            local devpath="/sys/bus/usb/devices/$(iface_to_dev "$SEL_IFACE")/authorized"
            if [[ -f "$devpath" ]]; then
                echo 0 > "$devpath"; sleep 1; echo 1 > "$devpath"
                ok "USB device re-enumerated"
            fi
        fi
    fi

    # 4. Wait for block device to appear
    log "Waiting for block device to appear (up to 20s)..."
    local t=0
    while (( t < 20 )); do
        local blk; blk=$(block_dev_for_iface "$SEL_IFACE")
        if [[ -n "$blk" && -b "/dev/$blk" ]]; then
            SEL_BLOCK="$blk"
            ok "Block device ready: /dev/$SEL_BLOCK"
            return 0
        fi
        sleep 1; ((t++)) || true
    done

    warn "Block device did not appear within 20 seconds."
    echo
    echo "  The drive may need a physical replug after the UAS error storm."
    ask "Replug the drive now, then press Enter to retry (Ctrl+C to abort):"; read -r _
    echo

    # After replug, the device re-enumerates — find it again
    mapfile -t FRESH_IFACES < <(list_driver_ifaces uas)
    for iface in "${FRESH_IFACES[@]}"; do
        local info; info=$(usb_info "$iface")
        local vp="${info%%|*}"
        if [[ "$vp" == "${SEL_VID}:${SEL_PID}" ]]; then
            SEL_IFACE="$iface"
            apply_runtime_fix   # recurse once after replug
            return
        fi
    done

    err "Device not found after replug. Verify the drive and try again."
    exit 1
}

# ═════════════════════════════════════════════════════════════════════════════
# PERMANENT FIX (modprobe.d + initramfs)
# ═════════════════════════════════════════════════════════════════════════════
make_permanent() {
    banner "Applying Permanent Fix"

    local vidpid="${SEL_VID}:${SEL_PID}"
    local conf="/etc/modprobe.d/usb-storage-quirks.conf"

    if [[ -f "$conf" ]]; then
        # Extract existing quirks value
        local existing
        existing=$(grep -E "^options usb-storage quirks=" "$conf" | sed 's/options usb-storage quirks=//' | tail -1)
        if [[ "$existing" == *"$vidpid"* ]]; then
            ok "Permanent quirk already in $conf"
        else
            # Append device to existing quirks list
            local merged="${existing:+${existing},}${vidpid}:u"
            # Replace the line in-place
            if grep -q "^options usb-storage quirks=" "$conf"; then
                sed -i "s|^options usb-storage quirks=.*|options usb-storage quirks=${merged}|" "$conf"
            else
                echo "options usb-storage quirks=${merged}" >> "$conf"
            fi
            ok "Updated $conf  →  quirks=${merged}"
        fi
    else
        cat > "$conf" <<EOF
# Generated by uas-fix.sh
# Forces usb-storage (BOT) instead of UAS for problematic drives.
# 'u' flag: UAS device forced to use Bulk-Only Transport.
options usb-storage quirks=${vidpid}:u
EOF
        ok "Created $conf"
    fi

    # Rebuild initramfs so the quirk is baked in for early USB enumeration
    rebuild_initramfs
}

rebuild_initramfs() {
    log "Rebuilding initramfs..."
    if   command -v mkinitcpio    &>/dev/null; then mkinitcpio -P        && ok "initramfs rebuilt (mkinitcpio)"
    elif command -v dracut        &>/dev/null; then dracut --force        && ok "initramfs rebuilt (dracut)"
    elif command -v update-initramfs &>/dev/null; then update-initramfs -u && ok "initramfs rebuilt (update-initramfs)"
    else warn "No initramfs tool found. Rebuild manually after reboot if needed."
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# NTFS REPAIR
# ═════════════════════════════════════════════════════════════════════════════
fix_ntfs() {
    [[ -n "$SEL_BLOCK" && -b "/dev/$SEL_BLOCK" ]] || return 0

    # Find NTFS partitions (use raw output to avoid tree chars)
    local ntfs_parts=()
    while IFS= read -r line; do
        local name fstype
        name=$(echo "$line" | awk '{print $1}')
        fstype=$(echo "$line" | awk '{print $2}')
        [[ "$fstype" == "ntfs"* ]] && ntfs_parts+=("$name")
    done < <(lsblk -rno NAME,FSTYPE "/dev/$SEL_BLOCK" 2>/dev/null | tail -n +2)

    [[ ${#ntfs_parts[@]} -eq 0 ]] && return 0

    banner "NTFS Volume Repair"

    if ! command -v ntfsfix &>/dev/null; then
        warn "ntfsfix not found — skipping NTFS repair."; return 0
    fi

    for part in "${ntfs_parts[@]}"; do
        local pdev="/dev/$part"
        [[ -b "$pdev" ]] || continue
        # Check if already mounted — skip ntfsfix for mounted partitions
        local pmnt
        pmnt=$(lsblk -dno MOUNTPOINT "$pdev" 2>/dev/null)
        if [[ -n "$pmnt" && "$pmnt" != "-" ]]; then
            ok "$pdev already mounted at $pmnt — skipping ntfsfix"
            continue
        fi
        log "Running ntfsfix on $pdev ..."
        if ntfsfix -d "$pdev"; then
            ok "$pdev: dirty flag cleared"
        fi
        if ntfsfix "$pdev"; then
            ok "$pdev repaired"
        else
            warn "$pdev: ntfsfix reported issues — run chkdsk from Windows for full repair."
        fi
    done
}

# ═════════════════════════════════════════════════════════════════════════════
# MOUNT
# ═════════════════════════════════════════════════════════════════════════════
mount_partitions() {
    [[ -n "$SEL_BLOCK" && -b "/dev/$SEL_BLOCK" ]] || return 0
    banner "Mounting Partitions"

    local media_base="/run/media/$REAL_USER"
    mkdir -p "$media_base"

    # Parse partitions (raw, no tree chars)
    while IFS= read -r line; do
        local name fstype mountpoint
        name=$(echo "$line" | awk '{print $1}')
        fstype=$(echo "$line" | awk '{print $2}')
        mountpoint=$(echo "$line" | awk '{print $3}')

        local pdev="/dev/$name"
        [[ -b "$pdev" ]] || continue
        [[ -z "$fstype" || "$fstype" == "swap" ]] && continue

        if [[ -n "$mountpoint" && "$mountpoint" != "-" ]]; then
            ok "$pdev already mounted at $mountpoint"; continue
        fi

        # Pick mount point label > partition name
        local label; label=$(lsblk -dno LABEL "$pdev" 2>/dev/null)
        local mntname="${label:-$name}"
        local mntpoint="$media_base/$mntname"
        mkdir -p "$mntpoint"

        local mounted=false

        if [[ "$fstype" == "ntfs"* ]]; then
            # Try kernel ntfs3 first (modern, fast); fall back to ntfs-3g
            if mount -t ntfs3 -o "force,uid=$REAL_UID,gid=$REAL_GID,noatime" \
                    "$pdev" "$mntpoint" 2>/dev/null; then
                mounted=true
            elif command -v ntfs-3g &>/dev/null && \
                 ntfs-3g -o "force,uid=$REAL_UID,gid=$REAL_GID,noatime" \
                    "$pdev" "$mntpoint" 2>/dev/null; then
                mounted=true
            fi
        else
            if mount -o "noatime" "$pdev" "$mntpoint" 2>/dev/null; then
                mounted=true
            fi
        fi

        if $mounted; then
            ok "Mounted $pdev → $mntpoint"
        else
            # Last resort: udisksctl (will pick its own mount point)
            if command -v udisksctl &>/dev/null; then
                local ud_out
                if ud_out=$(udisksctl mount -b "$pdev" 2>&1); then
                    rmdir "$mntpoint" 2>/dev/null || true
                    ok "$pdev mounted via udisksctl  ($ud_out)"
                else
                    rmdir "$mntpoint" 2>/dev/null || true
                    warn "Could not mount $pdev — try manually: mount $pdev /mnt"
                fi
            else
                rmdir "$mntpoint" 2>/dev/null || true
                warn "Could not mount $pdev — try manually: mount $pdev /mnt"
            fi
        fi

    done < <(lsblk -rno NAME,FSTYPE,MOUNTPOINT "/dev/$SEL_BLOCK" 2>/dev/null | tail -n +2)
}

# ═════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═════════════════════════════════════════════════════════════════════════════
print_summary() {
    banner "Summary"
    echo -e "  Device    : ${BOLD}${SEL_NAME}${RESET}  (${SEL_VID}:${SEL_PID})"
    echo -e "  Interface : $SEL_IFACE"
    echo -e "  Driver    : $SEL_DRIVER"
    [[ -n "$SEL_BLOCK" ]] && echo -e "  Block dev : ${GREEN}/dev/$SEL_BLOCK${RESET}"

    # Show mount status for partitions
    if [[ -n "$SEL_BLOCK" && -b "/dev/$SEL_BLOCK" ]]; then
        echo
        while IFS= read -r line; do
            local pname pfs pmnt
            pname=$(echo "$line" | awk '{print $1}')
            pfs=$(echo "$line" | awk '{print $2}')
            pmnt=$(echo "$line" | awk '{$1=""; $2=""; print}' | sed 's/^ *//')
            [[ -z "$pfs" ]] && continue
            if [[ -n "$pmnt" && "$pmnt" != "-" ]]; then
                echo -e "  Partition : ${GREEN}/dev/$pname${RESET} → $pmnt"
            else
                echo -e "  Partition : ${YELLOW}/dev/$pname${RESET} (not mounted)"
            fi
        done < <(lsblk -rno NAME,FSTYPE,MOUNTPOINT "/dev/$SEL_BLOCK" 2>/dev/null | tail -n +2)
    fi

    echo
    if [[ -f /etc/modprobe.d/usb-storage-quirks.conf ]] && \
       grep -q "${SEL_VID}:${SEL_PID}" /etc/modprobe.d/usb-storage-quirks.conf 2>/dev/null; then
        echo -e "  ${GREEN}Permanent fix${RESET} : /etc/modprobe.d/usb-storage-quirks.conf"
        warn "On next plug-in the drive will automatically use usb-storage (no further steps needed)."
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# MAIN
# ═════════════════════════════════════════════════════════════════════════════
main() {
    clear
    echo -e "${BOLD}${CYAN}"
    cat <<'BANNER'
  ╔═══════════════════════════════════════════════════════════╗
  ║        4KN / UAS USB Drive Fix  —  uas-fix.sh            ║
  ║   Arch Linux · Debian/Ubuntu · Fedora · AlmaLinux/RHEL   ║
  ╚═══════════════════════════════════════════════════════════╝
BANNER
    echo -e "${RESET}"

    detect_distro
    install_deps
    select_device

    if [[ "$SEL_DRIVER" == "uas" ]]; then
        apply_runtime_fix
        make_permanent
    else
        ok "Device already using usb-storage (UAS fix not needed)"
        # Still offer to make the quirk permanent if not already done
        local quirk_conf="/etc/modprobe.d/usb-storage-quirks.conf"
        local vidpid="${SEL_VID}:${SEL_PID}"
        if [[ -f "$quirk_conf" ]] && grep -q "$vidpid" "$quirk_conf"; then
            ok "Permanent quirk already in place for $vidpid"
        else
            echo
            ask "Save permanent UAS quirk for ${SEL_NAME}? [Y/n]:"; read -r yn
            case "${yn,,}" in
                n|no) log "Skipping permanent quirk." ;;
                *)    make_permanent ;;
            esac
        fi
    fi

    fix_ntfs

    echo
    ask "Mount detected partitions now? [Y/n]:"; read -r yn
    case "${yn,,}" in
        n|no) log "Skipping mount." ;;
        *)    mount_partitions ;;
    esac

    print_summary
}

main "$@"
