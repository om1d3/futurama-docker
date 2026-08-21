# removing Windows 11 from amy

**document version:** 1.0
**infrastructure version:** amy 20260810.2
**last updated:** august 2026

amy carried a Windows 11 installation on 109.35 GB of a 238 GB disk. Linux
upgrades made it unbootable, and a repair was not wanted. The only reason to
keep it was the driver set, because Sony removed the downloads for this
hardware from its website.

This document records what was preserved, how the partitions were removed, and
how to put the drivers back on a future Windows installation.

---

## contents

- [what was preserved](#what-was-preserved)
- [how the drivers were extracted](#how-the-drivers-were-extracted)
- [how to reinstall the drivers](#how-to-reinstall-the-drivers)
- [the disk before the removal](#the-disk-before-the-removal)
- [how to remove the partitions](#how-to-remove-the-partitions)
- [what to do with the space](#what-to-do-with-the-space)
- [what this archive is not](#what-this-archive-is-not)

---

## what was preserved

**Location:** `bender:/mnt/BIG/filme/archive/amy-windows-drivers/`

| directory | size | contents |
|-----------|------|----------|
| `FileRepository/` | 706 MB | the Windows driver store, 1456 `.inf` files |
| `INF/` | 60 MB | the driver information files that Windows uses to match hardware |
| **total** | **766 MB** | 376 `.sys` files across both |

No vendor software was found. `Program Files\Sony`, `Program Files (x86)\Sony`
and `ProgramData\Sony` did not exist, therefore this machine carried no Sony
control panel, hotkey utility, or setup program. The driver store is the whole
of what was installed.

### where it sits, and why

The archive is at `/mnt/BIG/filme/archive/`, deliberately **outside**
`configs/`. `configs/` is a source in `bender-replicate.sh`, and 766 MB of
static vendor files does not belong in a nightly replica to amy. It is also not
in the `futurama-docker` manifest, for the same reason.

Protection is ZFS snapshots. That is sufficient: the files never change, and
they are useless without the hardware.

---

## how the drivers were extracted

Windows did not boot, therefore `Export-WindowsDriver` could not run. The files
were copied from Debian instead, through the read-only NTFS mounts at
`/mnt/win_boot` and `/mnt/win_root`.

**The copy runs FROM bender, not from amy.** Three facts make that necessary,
and each one is a property of this infrastructure rather than an accident.

1. `/mnt/BIG/filme` is mode 770, owner `filme:filme`. The `admin` account on
   bender has the groups `admin`, `builtin_administrators` and `docker`. It has
   no execute permission on that directory, therefore it cannot descend into
   it, whatever the destination directory itself permits.
2. TrueNAS disables SSH for root. A push from amy to `root@10.30.0.12`
   therefore cannot work.
3. bender's root already reaches amy's root without a password.
   `bender-replicate.sh` and `futurama-sync.sh` both use that path each night.

So the direction is a pull, run as root on bender:

```bash
rsync -a --info=progress2 \
  root@10.30.0.11:/mnt/win_root/Windows/System32/DriverStore/FileRepository/ \
  /mnt/BIG/filme/archive/amy-windows-drivers/FileRepository/

rsync -a --info=progress2 \
  root@10.30.0.11:/mnt/win_root/Windows/INF/ \
  /mnt/BIG/filme/archive/amy-windows-drivers/INF/
```

Transfer took 15 seconds at 76 MB/s over the 10G path.

### verification

```bash
du -sh /mnt/BIG/filme/archive/amy-windows-drivers/*
find /mnt/BIG/filme/archive/amy-windows-drivers -name "*.inf" | wc -l
find /mnt/BIG/filme/archive/amy-windows-drivers -name "*.sys" | wc -l
```

Measured on 2026-08-21: 706 MB, 60 MB, 1456 `.inf`, 376 `.sys`.

---

## how to reinstall the drivers

On a fresh Windows installation on this hardware.

**Step 1. Copy the archive to the machine.** A USB stick, or a network copy
from bender. Put it at `C:\driver-backup`.

**Step 2. Install everything that matches the hardware.** From an
administrator command prompt:

```
pnputil /add-driver C:\driver-backup\FileRepository\*.inf /subdirs /install
```

`/subdirs` walks every subdirectory. `/install` installs each driver that
matches a present device, rather than only staging it. This takes several
minutes and reports a count when it finishes.

**Step 3. Let Windows find the rest.**

```
pnputil /scan-devices
```

**Step 4. Find what is still missing.**

```
pnputil /enum-devices /problem
```

That lists each device with no working driver. The list should be empty or very
short.

**Step 5, for a stubborn device.** Device Manager, right-click the device,
Update driver, Browse my computer, then point at
`C:\driver-backup\FileRepository` with **Include subfolders** ticked. Windows
searches every `.inf` for a hardware ID match.

### which drivers came from Sony

Most of `FileRepository` is Microsoft's own inbox drivers, which a fresh
Windows brings with it. The valuable minority is what Sony supplied. To list
them:

```powershell
Get-ChildItem C:\driver-backup\FileRepository -Recurse -Filter *.inf |
  Select-String -Pattern "Provider" | Select-String -NotMatch "Microsoft"
```

This is not necessary for the install. `pnputil` with `/subdirs` handles the
whole folder without sorting it.

---

## the disk before the removal

```
Disk /dev/sda: 238.47 GiB, SanDisk SD7SB6S-

Device      Start        End      Sectors    Size  Id  Type
/dev/sda1  *   63     102462       102400     50M   7  NTFS  System Reserved
/dev/sda2  106496  229304319   229197824  109.3G   7  NTFS  Windows
/dev/sda3  229306366 500117503 270811138  129.1G   5  Extended
/dev/sda5  229306368 500117503 270811136  129.1G  83  Linux  /
```

Two facts matter for what follows.

**The Windows partitions come FIRST on the disk.** Deleting them leaves free
space at the start, before the extended partition that holds root.

**Root is a logical partition inside an extended partition.** A logical
partition can only grow into free space inside its own container. Therefore
`sda5` cannot simply be extended into the reclaimed space.

`/etc/fstab` carried two mounts, on lines 14 and 15:

```
UUID=A23437E63437BBDB   /mnt/win_boot   ntfs   defaults   0   0
UUID=E45253FF5253D4C0   /mnt/win_root   ntfs   defaults   0   0
```

`/boot/grub/grub.cfg` carried two Windows entries, added by `os-prober`.

---

## how to remove the partitions

Do these in order. Step 3 is the one that can stop amy from booting.

**Step 1. Remove the mounts from fstab.**

```bash
cp /etc/fstab /etc/fstab.pre-windows-removal.backup
sed -i '/win_boot/d; /win_root/d' /etc/fstab
grep -n "win_" /etc/fstab
```

The `grep` must return nothing.

**Step 2. Unmount and remove the mount points.**

```bash
umount /mnt/win_boot /mnt/win_root
lsblk -f
rmdir /mnt/win_boot /mnt/win_root
```

`lsblk` must show no mount point against `sda1` or `sda2`.

**Step 3. Find out where the bootloader lives. Do not skip this.**

`sda1` carries the boot flag. If the machine chain-loads through the Windows
boot partition, deleting `sda1` stops amy from booting and recovery needs
external media.

```bash
dd if=/dev/sda bs=512 count=1 2>/dev/null | strings | grep -i grub
```

Output naming GRUB means GRUB is in the MBR and `sda1` is safe to delete.
No output means STOP and find out what is in the MBR first.

**Step 4. Delete the two partitions.**

```bash
fdisk /dev/sda
```

Then `d`, `1`, `d`, `2`, `p` to review, and `w` to write. Nothing changes
until `w`.

**Step 5. Regenerate the boot menu.**

```bash
update-grub
grep -c "Windows" /boot/grub/grub.cfg
```

The count must be `0`. `os-prober` finds no Windows because the partitions are
gone.

**Step 6. Confirm before rebooting.**

```bash
lsblk -f
parted /dev/sda print free
```

`parted` shows where the free space landed, which decides the next section.

---

## what to do with the space

109.35 GB becomes free at the **start** of the disk. Root is at the end, inside
an extended partition, therefore it cannot grow into it directly.

Three options.

### A. A separate filesystem for the replica. RECOMMENDED.

Create one primary partition in the free space, format it, and mount it at
`/docker/backups`.

```bash
fdisk /dev/sda          # n, p, 1, accept defaults, w
mkfs.ext4 -L backups /dev/sda1
blkid /dev/sda1         # note the UUID
```

Then move the existing replica. **Use `rsync -aH`.** The replica uses hardlinks
between daily snapshots, and a copy that does not preserve them multiplies the
size by the number of snapshots.

```bash
mkdir -p /mnt/newbackups
mount /dev/sda1 /mnt/newbackups
rsync -aH --info=progress2 /docker/backups/ /mnt/newbackups/
```

Then add it to `fstab` by UUID, unmount, and mount it over `/docker/backups`.

**Why this is the right option.** The replica is amy's largest and
fastest-growing consumer. On its own filesystem it can never again fill the
root partition. That matters because `bender-replicate.sh` aborts when amy has
less than 10 GB free, so a full root partition stops bender's backups.

### B. Move the partitions and grow root

Boot GParted Live, delete the NTFS partitions, move `sda3` and `sda5` to the
start of the disk, then grow both. This gives one large root filesystem.

It is a long offline operation on a disk that is 84 percent full. An
interruption during the move loses the filesystem. Only take this if a single
large root is worth that risk.

### C. Leave the space empty

Recovers nothing usable. It does remove the temptation to boot Windows again.

---

## what this archive is not

| it is not | why |
|-----------|-----|
| a recovery image | it holds drivers, not the installation |
| a set of installers | the driver store holds the files Windows uses, not vendor setup programs |
| a licence | the Windows licence is in the machine firmware, or it is gone |
| a backup of any data | no user files were kept. Check before deleting if that is wrong. |
| replicated to amy | it sits outside `configs/`, therefore ZFS snapshots are the only copy |

**Before the partitions are deleted**, confirm that no user data remains on
them. Once `fdisk` writes, the NTFS filesystems are gone.

```bash
du -xh --max-depth=2 /mnt/win_root/Users 2>/dev/null | sort -h | tail
```

---

*Written when the drivers were archived on 2026-08-21. Update it when the
partitions are actually removed, and record which option was taken for the
reclaimed space.*
