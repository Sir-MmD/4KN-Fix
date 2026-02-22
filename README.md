# 4KN-Fix

Fix 4KN / UAS USB drive recognition issues on Linux.
Supports **Arch · Debian/Ubuntu · Fedora · AlmaLinux/RHEL** (and derivatives).

---

## One-click run

```bash
curl -fsSL https://raw.githubusercontent.com/Sir-MmD/4KN-Fix/refs/heads/main/4kn-fix.sh | sudo bash
```

---

## What it does

1. Detects your distro and installs missing dependencies
2. Lists all UAS-bound USB devices and lets you pick one
3. Switches the drive from the broken UAS driver to `usb-storage` — live, no reboot
4. Writes a permanent fix to `/etc/modprobe.d/usb-storage-quirks.conf` and rebuilds initramfs
5. Runs `ntfsfix` if the partition is NTFS
6. Optionally mounts the drive

---

## Manual usage

```bash
curl -fsSL https://raw.githubusercontent.com/Sir-MmD/4KN-Fix/refs/heads/main/4kn-fix.sh -o 4kn-fix.sh
sudo bash 4kn-fix.sh
```

---

## Why

Some USB drives — especially **4KN** (4096-byte native sector) drives — fail silently under the UAS (USB Attached SCSI) driver with repeated `data cmplt err -75` errors. The kernel sees the drive but can't read it. Forcing `usb-storage` (Bulk-Only Transport) fixes this instantly.

---

*Written by Claude (Sonnet 4.6)*
