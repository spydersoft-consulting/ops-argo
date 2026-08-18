# pxhp: Smart Array cache module failure → ext4 corruption

`pxhp` (192.168.1.25, part of the 2-node PVE cluster with `pmxdell`/192.168.60.12)
has a recurring hardware fault on its embedded HPE Smart Array RAID controller.
This has hit at least three times: **2026-07-04**, **2026-07-05**, and
**2026-07-18**, each time getting back up the same way.

## Symptoms

On boot, the console shows, in this order:

1. A wall of `DMAR: ERROR: DMA PTE for vPFN 0x... already set (to X not Y)` —
   IOMMU/VT-d faults.
2. `NMI: IOCK error (debug interrupt?) for reason 71/61 on CPU 0`.
3. `EXT4-fs (dm-1): failed to convert unwritten extents to written extents --
   potential data loss!`
4. `EXT4-fs error (device dm-1): ext4_journal_check_start:84: ... Detected
   aborted journal`
5. `EXT4-fs (dm-1): Remounting filesystem read-only`

`dm-1` is `/dev/mapper/pve-root`.

## Root cause

**Not a bad drive, not RAM, not an IOMMU misconfiguration.** It's the embedded
Smart Array controller's write cache module (FBWC/BBWC).

Confirmed via the iLO Integrated Management Log (IML):

- `1798 - Slot X Drive Array - Cache Module Self-Test Error Occurred - Caching
  is disabled`
- `1719 - A controller failure event occurred prior to this power-up`
- `Uncorrectable PCI Express Error (Embedded device, Bus 0, Device 2, Function
  2)` — this is the embedded Smart Array controller.
- `Unrecoverable System Error (NMI) has occurred`
- On the 07-05 incident, dmesg also showed `Previous lock up code = 0x13`,
  which on HP P4xx controllers specifically means **the controller locked up
  due to a cache module failure**.

Chain of events: cache module fails its self-test (originally triggered by a
brownout on 07-04/05, cause of the 07-18 recurrence not yet confirmed) →
controller faults → uncorrectable PCIe error on the controller device → OS
sees this as DMAR DMA-remap faults + IOCK NMI → in-flight writes to the array
get corrupted → ext4 journal aborts → filesystem remounts read-only.

The recurrence pattern is accelerating: quiet from 07-05 to 07-18, then on
07-18 it cycled multiple times within hours (10:20, 15:13, 15:16, 21:37,
21:46, 21:49 per IML timestamps). This points to a degrading controller/cache
module, not a one-off event. **Treat fsck/rescue-mode recovery as a stopgap,
not a fix** — HP support engagement on the embedded Smart Array controller is
the real remediation.

## Recovery procedure (confirmed working 07-05 and 07-18)

1. Reboot `pxhp`. Watch the iKVM/console — when GRUB appears, press a key to
   stop the countdown (Proxmox disables the separate "(recovery mode)" GRUB
   submenu by default via `GRUB_DISABLE_RECOVERY="true"`, so there's no
   dedicated entry to pick).
2. Highlight the normal Proxmox VE kernel entry, press `e` to edit.
3. Find the `linux ...` line (has `root=/dev/mapper/pve-root ro quiet` on
   it). Append to the end:
   ```
   systemd.unit=rescue.target
   ```
   (Do **not** use `init=/bin/bash` — tried this 07-05 and it's a dead end on
   this box: the initramfs's `libdevmapper` doesn't match the running kernel,
   so `/proc`/`/sys`/`/dev` can't be mounted and no block devices show up.
   `emergency.target` is untested/unnecessary here — `rescue.target` is what
   has worked both times.)
4. Boot the edited line (Ctrl+X / F10). `rescue.target` mounts `/proc`,
   `/sys`, `/dev`, runs udev, and activates LVM automatically — no manual
   `vgchange -ay` etc. needed.
5. Once at the rescue shell, check state (systemd's own boot sequence
   typically already auto-fscks and remounts rw on its own — both 07-05 and
   07-18 came back clean without any manual fsck):
   ```
   lsblk
   lvs
   dmesg | grep -iE "ext4|error|journal"
   mount | grep dm
   ```
   `pve-root` is `dm-1`/`252:1`. Confirm no partial/failed `lv_attr` flags in
   `lvs` (a `p` flag would mean a failed LV — hasn't happened either
   incident).
6. **If dmesg already shows `pve-root` remounted `rw` with no errors in this
   boot**, you're done — skip straight to step 8.
7. **Only if still read-only / showing errors**, force a manual check:
   ```
   e2fsck -f /dev/mapper/pve-root
   ```
   Repeat until a pass comes back clean.
8. Reboot:
   ```
   reboot
   ```
   Not `systemctl reboot` — D-Bus isn't fully up under `rescue.target`, so
   `systemctl` fails with `Failed to connect to bus: No such file or
   directory`. This is expected/harmless in rescue mode; the plain `reboot`
   command works directly.

Other LVs on the `pve`/`pxhp-thin-01`/`pxhp-thin-02` VGs don't get fscked the
same way: `pve-swap` has no filesystem, and the thin pools (`data`,
`pxhp-thin-01`, `pxhp-thin-02` — backing the VM/CT disks) need `thin_check` /
`lvconvert --repair` or per-guest-disk checks, not a plain `fsck`. So far
neither incident has shown corruption outside `pve-root`.

## Open items

- Get HP support engaged with this IML history — embedded Smart Array
  controller / cache module likely needs replacement.
- Confirm whether the 07-18 recurrence had a trigger (power event?) or if the
  controller is now failing without one, which would raise urgency.
- See [[project_pve_cluster_topology]] for cluster context (`pxhp` +
  `pmxdell` 2-node PVE cluster).
