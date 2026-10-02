# Feature: robot

Hetzner **Robot** (dedicated bare metal) element — composes with the upstream `baremetal`
platform: flavors **`baremetal-robot-gardener_prod-amd64`** and **`baremetal-robot-k3s_prod-amd64`**
(a k3s node instead of a Gardener worker — `features/k3s/README.md`; the builder names its artefacts
`baremetal-k3s-robot_prod-amd64-…`, and CI publishes its rootfs as
`Gardenlinux-1300-<version>-amd64-robot-k3s.tar.xz`). Everything below applies to both: the k3s flavor
installs the same way into the same `vg0` layout, where `k3s-vg0.service` finds installimage's
volume group and LocalPV-LVM provisions into its free extents. Its post-install installs
`nodepool-agent`, which gives the node its role when it is claimed (`features/k3s/README.md`, "Robot:
the bootstrap at claim time"); by hand, write `/etc/rancher/k3s/config.yaml` and run `k3s-role server`
(or `agent`) without `--now`. Deliberately different from
`hcloud`:

| Concern | hcloud (cloud) | robot (dedicated) |
|---|---|---|
| kernel | `linux-image-cloud-$arch` (VM drivers only) | full `linux-image-$arch` via `metal` (Intel igb/e1000e, AHCI, mdadm…) |
| provisioning | cloud-init + DataSourceHetzner (metadata/user_data) | **no metadata** — Robot has no metadata service; bootstrap = the pull-onboarding agent (`autosetup.go`), test access = rescue-injection. The gardener flavor has no cloud-init; the k3s flavor has it with the NoCloud datasource only, disabled at boot and run by the agent over the seed it writes |
| boot | classic `_legacy` dual / usi EFI-only | **UEFI**, as installed through installimage on RAID1 (systemd-boot on a mirrored ESP, measured 2026-09-14). The rootfs carries both paths (`metal` includes `_legacy`), but on legacy BIOS the RAID1 layout only boots with GRUB, which Garden Linux does not ship: BIOS means `SWRAID 0`. An auction box that arrives in legacy BIOS is switched once at the KVM console ([below](#uefi-is-the-supported-path-measured-2026-09-14)) |
| deploy | snapshot via hcloud-upload-image / rescue-dd | **installimage with the builder's `.tar` rootfs** (preferred, keeps the LVM layout) or rescue-dd; recovery = Robot API rescue+reset |
| network | DHCP (hcloud always answers) | DHCP on the primary NIC (Robot answers with the static primary IP — verified 2026-07-07 on an AX-class auction box); vSwitch = 802.1q VLAN sub-interface, **MTU 1400**, static IP — configured by the onboarding agent, not baked |
| carried over | DNS trim (same Hetzner recursors), inotify sysctls, sshd PermitRootLogin+Include fixes | same |

## Deploying it: installimage, not dd (corrected 2026-09-13)

This file used to say "`installimage` has no custom-image path". **That is wrong**, and the error
was load-bearing: it is why the dedicated Garden Linux move looked like it needed a second
provisioning path, and a second partitioning path with it.

**Nothing in `pkg/reimage` has to change.** `ManagedServer.spec.dedicated.installimageProfile`
already becomes installimage's `IMAGE` line (`autosetup.go`), and `IMAGE` accepts an
`http:`/`https:`/`ftp:` URL, an absolute path, or an NFS path (`functions.sh:929-931`). Pointing a
box at a Garden Linux rootfs is a field on the object, not a code change.

### MEASURED ON HARDWARE 2026-09-13: it installs, and it does not boot

A full run on an AX41 (rescue → installimage → inspect) settled what "works" means here, and the
two halves came apart:

| | |
|---|---|
| RAID1 across both NVMe, `/boot` as md0 outside the group, `vg0` with **375.81 GB free** | ✅ exactly the layout the rest of this file predicts |
| `/boot/vmlinuz-6.18.37-amd64`, `System.map`, `config` | ✅ extracted from the tarball |
| `/boot/initrd.img-6.18.37-amd64` | ✅ **regenerated during the install** — installimage's initramfs step drives dracut through the `update-initramfs` shim |
| `/etc/fstab` (`/boot` by UUID, root `/dev/vg0/root`) | ✅ |
| a bootloader | ❌ **none** |

```
# chroot: grub-install --no-floppy --recheck /dev/nvme0n1 2>&1
:   bash: line 1: grub-install: command not found
```

installimage still reported the step as `done`, and exited 0. That is the trap: **"installed" and
"boots" are two claims, and only the first one is checked.**

Both sides of the cause are fixed, not incidental:

- installimage accepts **grub and nothing else** — `functions.sh:1416` greps `BOOTLOADER` for
  `^grub$` and aborts with "No valid BOOTLOADER" otherwise.
- Garden Linux 2150.6.0 ships **`grub2-common` only**. The platform modules that `grub-install`
  needs (`grub-pc-bin`, `grub-efi-amd64-bin`) are not in the repository at all. Garden Linux boots
  with **systemd-boot** (`systemd-boot`, `systemd-boot-efi`, `bootctl`) or syslinux, and the
  installed root carries `/efi/{EFI,loader,syslinux,Default/<kver>/{linux,initrd}}` to match.

So this cannot be closed by adding a package the way `lvm2` and `mdadm` were — the GRUB packages do
not exist here. **The bootloader is installed from the post-install hook instead**, which
installimage runs inside the chroot: `nodepool-core`'s `pkg/nodeagent/bootloader.go` installs
syslinux when `grub-install` is absent, and does nothing when it is present, so the Ubuntu path is
untouched. `extlinux` is in this feature's `pkg.include` for it; `syslinux-common`, which carries
`/usr/lib/syslinux/mbr/mbr.bin`, was already in the image.

It generates its configuration from `/etc/fstab` rather than reusing the `syslinux.cfg` Garden Linux
stages in `/efi`: that file boots `root=LABEL=ROOT` and loads the kernel from `../Default/<kver>/`,
which describes Garden Linux's **own** disk layout. installimage lays down a different one — the
kernel in a separate `/boot`, the root an unlabelled logical volume. Pointing a bootloader at a
layout that is not on the disk is how a green install becomes a box only rescue can reach.

### AND THE LAYOUT ITSELF ONLY BOOTS WITH GRUB (measured 2026-09-13)

Installing syslinux was not enough, and the reason is structural rather than a detail. The install
succeeded, every check in the bootloader step passed — and the box did not come back.

| read from | first sector says |
|---|---|
| `/dev/md0` — the filesystem | `SYSLINUX` — extlinux wrote its boot record correctly |
| `/dev/nvme0n1p1` — what the MBR chainloads | `Missing operating system.` — stale code from an earlier install |

`mdadm --detail` reports metadata **1.2** and a **Data Offset of 4096 sectors**: the array's data
begins 2 MB into the partition, so the partition's sector 0 is not the filesystem's sector 0. A
chainloading MBR jumps to the wrong place. GRUB is immune because it writes core.img into the
post-MBR gap and its md module understands the layout — it never chainloads.

installimage sets `--metadata=1.2` (`functions.sh:2324`) and drops to 0.90/1.0 only for CentOS 6.x
and Ubuntu ≤ 11.04. **Its RAID layout assumes GRUB**, which is the same assumption its custom-image
documentation states outright. And `SWRAID` is global: a single partition cannot opt out, so
"/boot unmirrored, root mirrored" cannot be expressed.

So on legacy BIOS with a mirror, a non-GRUB bootloader cannot boot this layout at all. The choice is
`SWRAID 0` — no mirror, on drives already at 171% of rated endurance — or UEFI, where systemd-boot
reads an ESP: a plain FAT partition, not an md member, with no chainload in the path.

### UEFI is the supported path (measured 2026-09-14)

The paragraph that stood here called UEFI "a different question, deliberately left open". It was
answered the next day, on the same AX41, over four reimages: with the firmware switched to UEFI,
installimage adds the ESP (`PART /boot/efi esp`), the post-install puts systemd-boot on it
(`nodepool-core`'s `pkg/nodeagent/bootloader.go`: a metadata-1.0 mirror the firmware reads as plain
FAT, one UEFI boot entry per drive, `kernel-install` pointed at the ESP), and the box boots. So
the rule for a box of the pool is:

- **UEFI, with RAID1.** Switched once per box at the KVM console (free for three hours, ordered
  through Robot): `Boot from Onboard LAN` → `Onboard LAN UEFI PXE`, CSM disabled, **Secure Boot off**
  (or the rescue system and installimage stop working), and PXE kept first in the boot order (a UEFI
  install can push it down, and rescue goes with it). `docs/dedicated-nodes.md` in the monorepo's
  root has the same steps.
- **Legacy BIOS only without a mirror** (`SWRAID 0`, extlinux), for the reason above. The pool does
  not use it: its drives are far past their rated endurance, and a mirror is what turns a failed
  drive into an alert.

### Why this matters more than the packaging detail

The dedicated disk layout — `SWRAID 1`, `PART lvm vg0 all`, a sized root LV, and the remaining
extents left free for LocalPV-LVM — is installimage's output, and it is proven on hardware. A
rescue-dd of the `.raw` brings the image's OWN partition table and leaves no volume group, so it
would have cost that layout and bought an unproven partitioning path in exchange. Through
installimage, `DiskLayout` carries over untouched; only the image source moves.

### The artifact already exists

`gardenlinux/builder`'s `make_list_build_artifacts` lists `.build/<cname>-<commit>.tar`
**unconditionally** (the `.raw` is added only when the flavor has a platform), and the Makefile
rule that produces it is labelled *"configuring rootfs"* — the disk image is derived FROM that
tarball. installimage accepts `tar`, `tar.gz`/`tgz`, `tar.bz`/`tbz`/`tar.bz2`, `tar.xz`/`txz` and
`tar.zst` (`functions.sh:934-938`), so even the uncompressed `.tar` would do; CI publishes `.tar.xz`
to keep the asset small.

No repacking is needed to satisfy the "archive must not contain /dev, /proc, /sys" requirement:
`extract_image()` passes `--exclude 'dev' --exclude 'proc' --exclude 'sys'` itself
(`functions.sh:2903`).

### Where the image may come from, and one form that cannot work

`IMAGE` takes an `http(s)`/`ftp` URL, an absolute path, or an NFS path — but installimage derives
the *filename* from that value with a plain `basename`, which is string work on the last `/` and
knows nothing about query strings. Three consequences, all measurable with
`test/installimage-name.sh` before a box is touched:

| Form | Works | Why |
|---|---|---|
| `https://host/path/Gardenlinux-1300-…-amd64-robot.tar.xz` | **yes** | basename is the name we meant |
| `https://user:token@host/path/Gardenlinux-…-amd64-robot.tar.xz` | **yes** | credentials live in the authority; `wget` honours them, basename never sees them |
| `/root/Gardenlinux-…-amd64-robot.tar.xz` | **yes** | staged into the rescue system ourselves; no network, no credential |
| a **presigned** S3/object-storage URL | **no** | `X-Amz-Credential` contains literal slashes (`AK/20260913/nbg1/s3/aws4_request`), so basename returns the tail of the *signature*. installimage then aborts with "can not determine image arch from filename" — in the rescue system, after the disks are committed |

Two properties of the download are worth knowing whichever form is used, because they are
installimage's, not ours:

- It fetches with `wget -q --no-check-certificate --content-disposition`. **The TLS certificate is
  not verified.** Whatever is served becomes the node's root filesystem, so the URL forms buy
  confidentiality at best, never integrity — a checksum checked after the fact, or the local-path
  form, is the only way to know what landed.
- `--content-disposition` means the *server* can name the saved file. Since the name is the
  interface described below, a host that sends its own `Content-Disposition` can change which
  distro code path installimage takes.

### The filename is an interface

installimage parses the basename in `whoami()`, and three fields decide what happens to the box.
`test/installimage-name.sh` encodes this and enforces it in CI; run `--self-test` to see the five
ways it can go wrong.

| Field | Becomes | Why it matters |
|---|---|---|
| 1 | `IAM`, the distro code path | Matches `*suse*`/`*centos*`/`*ubuntu*`/`*arch*`/`*rocky*`/`*alma*`/`*rhel*` case-insensitively and **defaults to `debian`**. `Gardenlinux` matches nothing, so it gets the Debian path — the right one for an apt/dpkg system. |
| 2 | `IMG_VERSION` | Used in **bash arithmetic** in a dozen places (`debian.sh:116`, `functions.sh:1698`, `2305`, `3766`…). `2150.6.0` makes every one of those a syntax error that evaluates FALSE, silently skipping the modern branch. Must be an integer. We use **1300**: Garden Linux 2150 is Debian-13-derived, and 1300 lands in the modern band of every comparison (`debian_bookworm_image` is `>= 1200 && <= 1300`). |
| `-amd64-` | `IMG_ARCH` | Found by a sed needing the arch **between two dashes**. When it cannot be determined installimage **aborts** ("can not determine image arch from filename"), so the arch may not be the last field — hence the trailing `-robot`. |

So the published name is `Gardenlinux-1300-2150-6-0-amd64-robot.tar.xz`. The GL version keeps its
dots out of it too, because `IMAGENAME` is cut at the first dot.

Note what this rules out: the builder's own artifact name,
`baremetal-robot-gardener_prod-amd64-2150.6.0-<commit>.tar`, yields `IMG_VERSION=robot`.

### What is measured, and what is not

Measured on an AX41 (2026-09-13 and 2026-09-14, the **gardener** flavor): installimage's chroot steps
complete on the Garden Linux rootfs (fstab, the initramfs regenerated with `lvm2` and `mdadm` from
`pkg.include`), the installed system boots under UEFI from the mirrored ESP, and the node joins.
This section used to say that none of it had run on a box; the sections above had already said
otherwise.

Not measured: the **k3s** rootfs on hardware (it installs through the same path and has never
booted on a box), and cloud-init's stages run by the node agent on Garden Linux' own cloud-init
package (run on Debian 13's 25.1.4 with this flavor's configuration; `features/k3s/README.md`).

cloud-init: the gardener flavor has none (metal excludes `cloud`; no datasource is added). The k3s
flavor has it for the Cluster API bootstrap alone, with NoCloud as its only datasource and disabled
at boot (`features/k3s/exec.config`, step 6). Either way nothing instance-specific is baked:
everything a box learns about itself comes from the onboarding agent. vSwitch/VLAN is intentionally
NOT baked: VLAN id/IP are per-deployment, and the agent sets them.
