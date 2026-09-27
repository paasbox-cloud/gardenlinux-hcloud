## Feature: zfs

### Description
<website-feature>
This feature adds OpenZFS (userland + an out-of-tree kernel module, built by DKMS against the kernel
this image ships) so a node can host local ZFS datasets for a local-PV CSI.
</website-feature>

### Why it exists

A local-PV CSI (openebs ZFS-LocalPV) pins a volume to a node **by name** and cannot move it. On a
pooled dedicated box that only works if the box keeps **both** its disk and its node name across a
Machine replacement — which is exactly what `nodepool-core`'s `releasePolicy: Bind` / `ReadyBound`
provides. Without ReadyBound this feature is pointless: a replaced Machine gets a freshly
generated name, the PV's `nodeAffinity` names a node that no longer exists, and the volume is
unschedulable for ever.

What ZFS buys beyond storage, on exactly the machine where capacity is scarce:

* **clones** — one prepared workshop dataset, copy-on-write per participant, instead of N full copies;
* **snapshots** — "reset my lab to the start" in seconds, via `VolumeSnapshot`;
* **`zfs send`/`receive`** — the only path for moving state between sites, because hcloud has no
  volume snapshots at all.

### Opt-in, and why

This feature is **not** included by any flavour. Adding an out-of-tree module to an image has
consequences that should be chosen, not inherited:

* **Secure Boot.** The module is unsigned, so a Secure-Boot-enforcing flavour (`_usi`, signed) will
  refuse to load it. Use this on the Robot/dedicated flavours, where Secure Boot is not enforced.
* **Build time and size.** The module is compiled during the image build; headers and toolchain are
  purged afterwards, but the build itself costs minutes.
* **The data lifecycle becomes yours.** The wipe *is* the tenant boundary in this fleet. A pool that
  survives a release is precisely what the wipe exists to prevent, so destroying datasets between
  cohorts becomes a deliberate step (`zfs destroy`) that the platform no longer does for you.

Build a flavour with it by adding `zfs` to the element list, e.g.:

    ./build baremetal-gardener_prod_zfs-amd64

### What it does at build time

1. Determines the **one** kernel in `/lib/modules` and refuses to continue if there are zero or two —
   "which kernel did we build for" must not be a coin toss.
2. Builds and installs the module with `dkms build`/`dkms install` **for that kernel**. The
   `zfs-dkms` postinst cannot be trusted here: it builds for `uname -r`, which inside the build
   chroot is the *build host's* kernel, and the module would land under the wrong `/lib/modules`
   while the build still succeeded.
3. **Verifies** with `modinfo` that the module is registered, and that `zpool`/`zfs` exist. A failure
   here fails the BUILD — the alternative is a node that boots and then cannot mount anything.
4. Enables `zfs-import-cache`, `zfs-mount` and `zfs.target`, so a pool the CSI creates later comes
   back after a reboot without anybody logging in. Enabling them with no pool present is a no-op.
5. Purges the kernel headers and toolchain. A production node has no business carrying a compiler.

Deliberately **not** done: putting ZFS into the initramfs. Root stays ext4 and ZFS carries data only,
so the module is needed after `pivot-root`, not before — which also avoids rebuilding the initrd for
an out-of-tree module.

### The open question, now answered — and the answer is no

**Measured against the repo on 2026-09-12: Garden Linux 2150.6.0 carries no ZFS package at all, so
this feature cannot build as written.** It did not take a build to find out, only the package index:

```
https://packages.gardenlinux.io/gardenlinux/dists/2150.6.0/
  main/binary-amd64/Packages.gz         HTTP 200   — 2712 packages
  contrib/binary-amd64/Packages.gz      HTTP 404
  non-free/binary-amd64/Packages.gz     HTTP 404
```

`main` is the only component, and it holds nothing matching `zfs*`, `libzfs*`, `libnvpair*`,
`libuutil*` or `spl*`. Debian ships `zfs-dkms` and `zfsutils-linux` in **contrib**, which Garden
Linux does not publish for this dist. So `pkg.include` would fail at apt, exactly as this section
predicted — the prediction was right, the outcome is simply unavailable rather than untested.

What *is* present is the whole mechanism around it: `dkms` 3.2.2-1, `linux-headers-amd64`
6.18.37-1gl1~bp2150 and the matching `linux-headers-6.18.37-amd64`. The DKMS-against-the-image-kernel
approach in `exec.config` is therefore sound; only the ZFS sources are missing.

### Decided 2026-09-12: LVM thin, and this feature stays as a record

**The decision is LVM thin pools with OpenEBS LocalPV-LVM, not ZFS and not Btrfs.** `lvm2` and
`thin-provisioning-tools` are already in GL `main`, `dm-thin` is in-tree, and LocalPV-LVM has been GA
since August 2021 (~50 000 users) — against Btrfs CSI drivers that are all single-maintainer projects.
Btrfs was briefly recommended on filesystem merits, which was the wrong thing to judge: the CSI is what
sits in the data path. Backup is Velero moving CSI snapshots off to object storage — a thin-pool
snapshot lives on the same box and protects against a bad `rm`, not against losing the box.

This feature is kept rather than deleted: it documents a measured repository fact and a sound
DKMS-against-the-image-kernel approach, and if ZFS is ever genuinely wanted the cheap route is Ubuntu
on the pool that has the disks (which is what it runs today), not packaging ZFS for Garden Linux.
The reasoning is the same one the storage documentation gives: a snapshot that lives on the
same box as its volume protects against a mistake, not against losing the box.

### The three ways out, and what each costs

1. **Add Debian `trixie contrib` as a second apt source.** Gets the two packages, and needs apt
   pinning so nothing else comes from Debian. The cost is a second trust root inside an OS image
   build — worth weighing against the CRA stance, which treats the OS as a
   Class I product.
2. **Build OpenZFS from upstream source** in `exec.config`. No new repo, but no apt upgrade path
   either, and the build has to carry a toolchain.
3. **Use Btrfs instead — recommended.** `btrfs-progs` 6.17.1-1 is already in GL main, and Btrfs is
   **in-tree**: no DKMS, no headers, no rebuild per kernel bump, and no module that can silently fail
   to load after an update. It gives what ZFS was wanted for here — snapshots and CoW clones for
   local PVs, which is the whole point for lab sessions — and RAID1 across the two NVMe (the AX41
   layout) is well-trodden Btrfs territory. What it gives up is ARC, mature send/receive and RAID-Z;
   none of those are on the path for a local-PV CSI. `lvm2` 2.03.31 plus `thin-provisioning-tools`
   1.1.0 are also in main, as a third option with thin snapshots but no filesystem-level checksums.

**Sequencing note:** none of this blocks the stateful line today. The dedicated pool runs Ubuntu
24.4.1 (`platform/shoot-hub.yaml`), and Ubuntu ships ZFS in its own repositories — so ZFS on the
AX41s is an apt install right now. Only the *Garden Linux* flavour is blocked, and Garden Linux for
the dedicated pool is a direction, not a prerequisite.

### Meta
|||
|---|---|
|type|element|
|included_features|metal|
|excluded_features|None|
