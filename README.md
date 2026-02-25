# 4KN-Fix

Interactive Linux drive diagnostic & fix toolkit.
Scans **all** block devices — USB, SATA, NVMe — diagnoses issues, and offers context-sensitive fixes.

---

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/Sir-MmD/4KN-Fix/refs/heads/main/4kn-fix.sh | sudo bash
```

Or download first:

```bash
curl -fsSL https://raw.githubusercontent.com/Sir-MmD/4KN-Fix/refs/heads/main/4kn-fix.sh -o 4kn-fix.sh
sudo bash 4kn-fix.sh
```

`--help` and `--version` work without root.

---

## How It Works

```
Scan all drives → Pick one → Auto-diagnose → Action menu (loop) → Back to drive list
```

### 1. Drive List

All block devices are listed with size, sector info, transport type, and status badges:

```
  4KN-Fix — Linux Drive Toolkit

  #   Device       Size    Sectors     Transport      Status
  ──────────────────────────────────────────────────────────────────
  1   /dev/sda     500G    512/512     SATA           [ok]
  2   /dev/sdb     2.0T    4096/4096   USB (UAS)      [UAS ERRORS] [dirty NTFS]
  3   /dev/sdc     1.0T    4096/512    USB            [not mounted]
  4   /dev/sdd     250G    512/512     USB            [dirty NTFS]
  5   /dev/sde     120G    512/512     SATA           [dirty ext4]
  6   /dev/nvme0   500G    512/512     NVMe           [ok]

  0   Exit

  Select a drive [0-6]:
```

**Badges:** `[ok]` `[4KN]` `[UAS ERRORS]` `[dirty NTFS]` `[dirty ext4]` `[dirty FS]` `[not mounted]` `[write-protected]` `[I/O errors]` `[no partitions]`

### 2. Diagnosis

After selecting a drive, everything is checked automatically:

```
─── Diagnostics: /dev/sdb — WD Elements 25A3 ───

  Transport     : USB (currently using UAS driver)
  USB ID        : 0b1f:9999
  Interface     : 4-4:1.0
  Size          : 2.0T
  Sector Size   : PHY=4096  LOG=4096  (4KN — native 4K)
  Write Protect : No

  Issues Found:
    ✗ UAS driver errors in dmesg
    ✗ /dev/sdb1 (ntfs, 1.8T): dirty flag set — needs repair
    ✗ /dev/sdb2 (exfat, 200G): not mounted
    ✓ SMART: PASSED
    ✓ No I/O errors in dmesg
```

For a non-USB drive, only relevant info is shown (no USB ID, no UAS actions).

### 3. Action Menu

Only actions relevant to the diagnosed issues appear:

```
  Actions:
  [1] Fix UAS → usb-storage (switch driver now)
  [2] Make UAS fix permanent (survives reboot)
  [3] Repair filesystems (ntfsfix on sdb1)
  [4] Mount partitions
  [5] SMART health details
  [6] Show dmesg errors
  [7] Rescan drive
  [8] Run all recommended fixes
  [0] Back to drive list
```

A SATA drive with only a dirty NTFS partition would show:

```
  Actions:
  [1] Repair filesystems (ntfsfix on sdd1)
  [2] SMART health details
  [3] Show dmesg errors
  [4] Rescan drive
  [0] Back to drive list
```

UAS options don't appear because it's not a USB drive. The menu adapts.

---

## Actions

### Fix UAS → usb-storage (USB+UAS only)

Switches a USB drive from the broken UAS driver to usb-storage at runtime:

- Injects a runtime quirk into `/sys/module/usb_storage/parameters/quirks`
- Unbinds from UAS, binds to usb-storage
- Auto-detects additional quirk flags from dmesg (`u`, `s`, `r`, `c`)
- Retries up to 3 times with a wait-and-replug prompt
- Verifies the block device is readable after switching

### Make UAS Fix Permanent (USB only)

Persists the UAS quirk across reboots:

- Writes to `/etc/modprobe.d/usb-storage-quirks.conf` (backs up existing, merges idempotently)
- Rebuilds initramfs (auto-detects mkinitcpio / dracut / update-initramfs)
- Prints the kernel cmdline alternative (`usb-storage.quirks=VID:PID:u`)

### Repair Filesystems

Repairs dirty or corrupt partitions based on filesystem type:

| Filesystem | Tool | Method |
|-----------|------|--------|
| NTFS | `ntfsfix` | `-d` to clear dirty flag, then repair pass |
| ext2/ext3/ext4 | `e2fsck` | `-p` auto-fix safe errors |
| exFAT | `fsck.exfat` | Standard check |
| btrfs | `btrfs check` | Read-only check first, `--repair` only with explicit confirmation |
| xfs | `xfs_repair` | `-n` check first, offers `-L` for dirty log |
| vfat/FAT32 | `fsck.vfat` | `-a` auto-fix |

Skips mounted partitions (offers to unmount first). Asks confirmation before each repair.

### Mount Partitions

Mounts unmounted partitions with filesystem-appropriate options:

- **NTFS**: kernel `ntfs3` driver first, falls back to `ntfs-3g` FUSE
- **exFAT**: kernel `exfat` first, falls back to `exfat-fuse`
- **ext4/xfs/btrfs/vfat**: standard kernel mount
- FUSE mounts set `uid`/`gid` to the real user (not root)
- `udisksctl` as a final fallback
- Mounts at `/run/media/$USER/<label_or_name>`

### SMART Health

Shows drive health using `smartctl`:

- Overall PASSED/FAILED status
- Key attributes: reallocated sectors, CRC errors, temperature, power-on hours
- NVMe-specific attributes (percentage used, available spare, data units)
- Uses `-d sat` passthrough for USB drives (gracefully handles unsupported drives)

### Show dmesg Errors

Filters and displays the last 30 dmesg lines related to the selected device, with errors highlighted in red.

### Rescan Drive

Triggers a device rescan and re-reads the partition table (`partprobe` or `blockdev --rereadpt`).

### Run All Recommended

Chains applicable fixes in order with a single confirmation:

1. UAS fix (if USB+UAS with errors) + optional permanent fix
2. Filesystem repair (if any dirty partitions)
3. Mount partitions (if any unmounted)

---

## Supported Distros

Dependencies are installed **lazily** — only when an action needs the tool.

| Distro | Package Manager |
|--------|----------------|
| Arch Linux (+ derivatives) | pacman |
| Debian / Ubuntu / Mint | apt |
| Fedora | dnf |
| RHEL / AlmaLinux / Rocky / CentOS | dnf (+EPEL) |
| openSUSE | zypper |
| Gentoo | emerge |
| Void Linux | xbps |
| Alpine Linux | apk |

For unsupported distros, the tool continues but asks you to install missing tools manually.

---

## CLI Options

```
-h, --help       Show help (works without root)
-V, --version    Show version
--no-color       Disable colored output
```

Colors are also auto-disabled when `NO_COLOR` is set, output is piped, or `TERM=dumb`.

---

## What Changed in v2.0

Previously, 4KN-Fix was a single-pass USB-only UAS fixer. v2.0 is a complete rewrite:

| | v1 | v2 |
|-|----|----|
| **Scope** | USB drives with UAS issues | All drives (USB, SATA, NVMe) |
| **Interface** | Linear (scan → fix → done) | Interactive menu loop |
| **UAS fix** | Always attempted | Only offered when UAS errors detected |
| **Filesystem repair** | NTFS only | NTFS, ext4, exFAT, btrfs, xfs, vfat |
| **Mounting** | Basic mount | ntfs3/ntfs-3g/exfat-fuse fallback chain |
| **Diagnostics** | Minimal | Sector type, SMART, dmesg, write-protect, dirty flags |
| **Dependencies** | Installed upfront | Lazy — installed only when needed |
| **Distros** | 4 families | 8 families |
| **Drive selection** | USB only | All block devices with status badges |
| **Actions** | Fixed pipeline | Context-sensitive menu (adapts to issues found) |

---

## Why

Some USB drives — especially **4KN** (4096-byte native sector) drives — fail under the UAS (USB Attached SCSI) driver with errors like `data cmplt err -75`. The kernel sees the drive but can't read it.

But drive problems go beyond UAS. Dirty NTFS volumes from Windows, ext4 journals that need replay, drives that won't mount — all common issues that this tool handles in one place.
