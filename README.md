# 4KN-Fix

Interactive Linux drive diagnostic & fix toolkit. Scans all drives, diagnoses issues, and offers context-sensitive fixes.

---

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/Sir-MmD/4KN-Fix/refs/heads/main/4kn-fix.sh | sudo bash
```

Or download and run:

```bash
curl -fsSL https://raw.githubusercontent.com/Sir-MmD/4KN-Fix/refs/heads/main/4kn-fix.sh -o 4kn-fix.sh
sudo bash 4kn-fix.sh
```

---

## What It Does

Scans **all** block devices (USB, SATA, NVMe), lets you pick one, diagnoses everything wrong with it, and offers to fix it.

### Handles

- **USB drives with UAS driver issues** — switches from broken UAS to usb-storage, with optional permanent fix
- **Dirty/corrupt filesystems** — NTFS, ext4, exFAT, btrfs, xfs, vfat
- **Drives that won't mount** — tries kernel drivers, FUSE fallbacks, and udisksctl
- **4KN alignment/compatibility** — detects native 4K sector drives
- **SMART health problems** — checks key attributes (with SAT passthrough for USB)
- **Write-protection false positives** — detects and reports write-protect status
- **I/O errors** — flags dmesg errors for any drive

### Interactive Flow

```
Scan all drives → Pick one → Auto-diagnose → Context-sensitive action menu
```

The action menu adapts to what's actually wrong:
- USB+UAS drives get: UAS fix, permanent fix
- Dirty FS drives get: filesystem repair
- Unmounted drives get: mount partitions
- All drives get: SMART details, dmesg errors, rescan
- "Run all recommended" shortcut chains applicable fixes
- "Back to drive list" to pick another drive

---

## Drive List

```
  4KN-Fix — Linux Drive Toolkit

  #   Device       Size    Sectors     Transport      Status
  ──────────────────────────────────────────────────────────────────
  1   /dev/sda     500G    512/512     SATA           [ok]
  2   /dev/sdb     2.0T    4096/4096   USB (UAS)      [UAS ERRORS] [dirty NTFS]
  3   /dev/sdc     1.0T    4096/512    USB            [not mounted]
  4   /dev/nvme0   500G    512/512     NVMe           [ok]

  0   Exit
```

Status badges: `[ok]` `[4KN]` `[UAS ERRORS]` `[dirty NTFS]` `[dirty ext4]` `[not mounted]` `[write-protected]` `[I/O errors]` `[no partitions]`

---

## Supported Distros

| Distro | Package Manager |
|--------|----------------|
| Arch Linux (and derivatives) | pacman |
| Debian / Ubuntu / Mint | apt |
| Fedora | dnf |
| RHEL / AlmaLinux / Rocky / CentOS | dnf (+EPEL) |
| openSUSE | zypper |
| Gentoo | emerge |
| Void Linux | xbps |
| Alpine Linux | apk |

Dependencies are installed **lazily** — only when an action actually needs a tool (e.g., `ntfsfix` is installed only when you choose to repair an NTFS partition).

---

## CLI Options

```
  -h, --help       Show help (works without root)
  -V, --version    Show version
  --no-color       Disable colored output
```

Colors are also auto-disabled when `NO_COLOR` is set, output is piped, or `TERM=dumb`.

---

## Why

Some USB drives — especially **4KN** (4096-byte native sector) drives — fail under the UAS (USB Attached SCSI) driver with errors like `data cmplt err -75`. The kernel sees the drive but can't read it.

But drive problems go beyond UAS. Dirty NTFS volumes from Windows, ext4 journals that need replay, drives that won't mount — all common issues that this tool handles in one place.
