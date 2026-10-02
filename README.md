> **Release snapshot.** This repository publishes `the Garden Linux build for Hetzner Cloud — recipe and scripts, build it in your own project` as one commit per release of the
> [PaaSbox](https://paasbox.com) platform (tag `v1.150.2-pb.73` = the platform train it ships in). It is supplied free of
> charge, as is, under the [LICENSE](LICENSE); PaaSbox's commercial offer is the operated service, which runs
> exactly this code. Images: `ghcr.io/paasbox-cloud/gardenlinux-hcloud:v1.150.2-pb.73`, signed. How to contribute and how to report a
> vulnerability: [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md). Why it is published this way:
> https://paasbox.com/docs/built-on-gardener/.

# gardenlinux-hcloud — Garden Linux images for Hetzner Cloud & Robot dedicated

A [gardenlinux/builder](https://github.com/gardenlinux/builder) configuration directory (the
`builder_example` layout) that builds two [Garden Linux](https://github.com/gardenlinux/gardenlinux)
flavors Hetzner users need and upstream does not ship:

- **`hcloud`** — for Hetzner Cloud instances: cloud-init with the Hetzner datasource. There is no
  upstream Garden Linux flavor for hcloud at all.
- **`robot`** — for Hetzner Robot dedicated servers: a full kernel and no metadata datasource, because
  a dedicated box has no metadata service to read user data from. It is installed through Hetzner's
  `installimage`, which is why this flavor also publishes a rootfs tarball rather than only a disk
  image. The Gardener flavor carries no cloud-init at all; the k3s flavor carries it for one job, the
  Cluster API bootstrap that arrives at claim time (`features/k3s/README.md`).

As a worker OS it replaces the drift that comes with tracking a general-purpose distribution — the
containerd pin, the AppArmor runc kill-denial, netplan MAC drift — and it supports in-place updates,
so a long-lived instance can be upgraded without being recreated (which, on price-locked Hetzner
instances, would forfeit the rate).

> Images are built by `.github/workflows/build.yml`: pushing a `v*` tag builds every flavor and
> publishes the artefacts as **GitHub Release assets** — `.raw.xz`, `.uki`, `.esp.tar`, the
> manifests, the `installimage`-shaped rootfs tarball, and a `SHA256SUMS` over all of them
> (GitHub's asset digests; not a signature). A build needs a GitHub runner with
> KVM and root; it is not something a laptop reproduces quickly. Per-project Hetzner
> **snapshots** are then made from those raws with `hcloud-upload-image` (below).

## Flavors

| cname | Boot | In-place | Use |
|---|---|---|---|
| `hcloud-gardener_prod-amd64` | BIOS+UEFI (`_legacy`) | no | universal fallback, incl. BIOS-only CX types |
| `hcloud-gardener_prod_usi-amd64` | EFI-only (USI/UKI) | **yes** (`gardenlinux-update`) | CPX/CCX pools, Layer-1 upgrades |
| `hcloud-gardener_prod-arm64` / `hcloud-gardener_prod_usi-arm64` | as above | as above | CAX (arm64) pools — built natively on GitHub's arm64 runners |
| `baremetal-robot-gardener_prod-amd64` | **UEFI** as installed (installimage, RAID1); BIOS only without RAID — [below](#robot-uefi-as-installed) | no | Robot dedicated servers — full kernel, no cloud-init (`features/robot/README.md`) |
| `baremetal-robot-gardener_prod_zfs-amd64` | as above | no | the same, **plus OpenZFS** for local-PV storage (`features/zfs/README.md`) |
| `hcloud-k3s_prod_usi-amd64` / `hcloud-k3s_prod_usi-arm64` | EFI-only (USI/UKI) | **yes** — the OS update is the k3s update | a **k3s node** instead of a Gardener worker: k3s in the image, state in `/var`, local volumes on LVM `vg0` — `local-lvm-thin` is the only default StorageClass; adding hcloud-csi next to it needs `defaultStorageClass: false` (`features/k3s/README.md`) |
| `baremetal-robot-k3s_prod-amd64` | as above | no | a k3s node on a Robot box, installed through installimage into its `vg0` layout; cloud-init with the NoCloud datasource only, run by the node agent at claim time |

<a id="robot-uefi-as-installed"></a>
**Robot flavors boot UEFI, as they are installed.** The rootfs itself carries both boot paths (`metal`
includes `_legacy`), and that is where "BIOS+UEFI" in this table came from. It is not what a box gets.
Through installimage on a RAID1 pair, which is the layout every box of the pool has, Garden Linux
boots **only under UEFI**: systemd-boot on a mirrored ESP, measured on an AX41 on 2026-09-14. On
legacy BIOS the same layout cannot be booted without GRUB, which Garden Linux does not ship; BIOS
works only with `SWRAID 0` (extlinux, no mirror), which the pool does not use. The firmware is
switched once per box at the KVM console (`features/robot/README.md`, and `docs/dedicated-nodes.md`
in the monorepo's root).

The `zfs` element is **opt-in and not part of any flavor above**: the module is out-of-tree, so a
Secure-Boot-enforcing flavor (`_usi`, signed) refuses to load it, and adding it changes an image that
has already been validated. It belongs on the Robot/dedicated flavors, where the disks are, Secure
Boot is not enforced, and `nodepool-core`'s ReadyBound keeps a box's disk and node name across a
Machine replacement — the precondition without which a local PV is unschedulable for ever. **Settled 2026-09-12 against the repo, and the answer is no:** Garden
Linux 2150.6.0 publishes only `main` (contrib and non-free are 404) and its 2712 packages contain
nothing from the ZFS family, so `features/zfs` cannot build as written. `dkms` and the matching
`linux-headers` *are* there, so the mechanism is sound and only the sources are missing. The way out
is a choice, and `features/zfs/README.md` lays out all three: Debian contrib as a second apt source,
an upstream source build, or **Btrfs** — in-tree, `btrfs-progs` already in main, snapshots and CoW
clones without DKMS, which is the recommendation. Nothing here blocks the stateful line today: the
dedicated pool runs Ubuntu 24.4.1, where ZFS is an apt install. `test/zfs-test.sh` is the hardware
half — module load, pool, snapshot, clone, and whether the pool comes back after a reboot.

The `k3s` element is the **alternative** to `gardener`, never an addition: k3s brings its own
containerd, so `features/k3s/info.yaml` excludes `gardener` and the builder refuses a flavor naming
both. The platform elements (`hcloud`, `robot`) are shared unchanged. There is deliberately no classic
`hcloud-k3s_prod`: without in-place updates a k3s upgrade would be a rebuild, which wipes the local
volumes (`features/k3s/README.md` says why and how it would be built if ever needed).

Naming follows upstream `flavors.yaml` exactly: platform `hcloud`/`baremetal` + element
`gardener`/`robot` + flags `_prod`/`_usi` (upstream ships e.g. `kvm-gardener_prod_usi-amd64`).

## The label contract (do not break)

Snapshots carry **`gardener.cloud/image-name=gardenlinux-<version>`** (e.g.
`gardenlinux-2150.6.0`). That one selector is shared by:
- CloudProfileConfig `providerConfig.machineImages[].versions[].imageName`,
- nodepool `ManagedServer.spec.imageRef`,
- the uploader below (the MCM driver `mcm-provider-hcloud` resolves the snapshot by that label,
  newest-by-Created wins).

**The k3s flavors use their own names**, one per k3s version **and** architecture (owner decision
2026-09-27), from `hack/k3s-image-labels.sh labels <amd64|arm64> [<k3s version>]`:

| label | value | e.g. |
|---|---|---|
| `gardener.cloud/image-name` | `gl-k3s-<vX.Y.Z>-<arch>` | `gl-k3s-v1.36.4-amd64` |
| `gl-k3s` | the full k3s version, `+` as `-` (a label value cannot hold `+`) | `v1.36.4-k3s1` |
| `gl-flavor` | the flavor | `hcloud-k3s_prod_usi-amd64` |

pool-manager resolves `ManagedServer.spec.imageRef` to the **newest** snapshot of the label whatever
its architecture or k3s, so a name shared across versions lets an upload change what the next claim
installs, and one shared across architectures can hand a claim the wrong disk. The management CLI refuses a
name shared across k3s versions, one that names no version, and one of the wrong architecture. The
k3s revision (`+k3sN`) is not in the name: before uploading a second revision of the same patch
release, delete or relabel the older snapshot in that project. The release's k3s UKI carries the
same name (`gl-k3s-v1.36.4-amd64.uki`, listed in the release's `SHA256SUMS`).

## Layout: ours vs vendored

```
features/hcloud/          OURS — the Hetzner Cloud platform feature (see its README for decisions)
features/robot/           OURS — the Robot dedicated element (see its README)
features/k3s/             OURS — the k3s node element, alternative to gardener (see its README)
get_repo|version|...      OURS — pins: packages.gardenlinux.io @ 2150.6.0, epoch 1771372800
build.config, .github/,
test/, hack/              OURS
build, keyring.gpg,
features/<everything else>,
cert/ tooling             VENDORED verbatim from gardenlinux/gardenlinux @ 2150.6.0 (VENDOR.md)
```

Vendoring is required, not a style choice: the builder mounts only this dir's `features/`, and
`parse_features` asserts every include/exclude-referenced feature exists locally (21-feature
closure). **Never edit vendored files** — bump `GL_TAG` in `hack/vendor-upstream.sh` (+ the
`get_version`/`get_timestamp` pins) and re-run it. Version bump tripwire: if GL release notes
show **containerd 2.3+** (config v4), Gardener must be ≥ v1.144 first.

## Build locally

Requires rootless podman (Linux). Classic flavor:

```sh
./build hcloud-gardener_prod-amd64
# → .build/hcloud-gardener_prod-amd64-2150.6.0-<commit8|local>.raw
```

USI flavor (generate self-signed dev certs once first — `_usi/exec.post` bakes
`cert/oci-sign.crt` + the four `secureboot.*.auth` blobs into the image):

```sh
./cert/build oci-sign.crt secureboot.pk.auth secureboot.null.pk.auth secureboot.kek.auth secureboot.db.auth
./build hcloud-gardener_prod_usi-amd64
# → …-2150.6.0-<commit>.raw (EFI-only disk) + ….uki + ….esp.tar
```

macOS: no native podman — use an OrbStack Linux machine (`orb create ubuntu gl-builder`,
`orb -m gl-builder sudo apt-get install -y podman`, then run the builds inside the machine;
copy this dir to a VM-local path first — virtiofs-backed workdirs are slow and can upset
rootless podman mounts).

## Upload to an hcloud project (GL1 — lab project ONLY for now)

[apricote/hcloud-upload-image](https://github.com/apricote/hcloud-upload-image) (rescue-boot +
dd + snapshot; disk zeroed → small snapshot; raw only — qcow2 is capped ~960MB):

```sh
xz -T0 -9 .build/hcloud-gardener_prod-amd64-2150.6.0-*.raw
export HCLOUD_TOKEN=<lab project rw token>
hcloud-upload-image upload \
  --image-path .build/hcloud-gardener_prod-amd64-2150.6.0-*.raw.xz \
  --compression xz \
  --architecture x86 \
  --location nbg1 \
  --description "Garden Linux 2150.6.0 hcloud-gardener_prod" \
  --labels gardener.cloud/image-name=gardenlinux-2150.6.0
```

Same for the USI raw. NOTE: while both variants are labeled `gardenlinux-2150.6.0` the label
resolver takes newest-by-Created — during GL1/GL2 keep only ONE variant per project, or suffix
the trial label (e.g. `…=gardenlinux-usi-2150.6.0`) and reconcile before GL4.

## Building the k3s snapshots locally (amd64 and arm64, 2026-09-27)

The first Hetzner snapshots of `hcloud-k3s_prod_usi-{amd64,arm64}`, built on an M3 Ultra Mac and uploaded to a
test project. Both flavors, each for k3s **v1.36.3+k3s1** and **v1.36.4+k3s1** (the pair the in-place
update 1.36.3 → 1.36.4 is tested with, `features/k3s/README.md` checks 4–5). Built from this directory at the
commit that added the metadata guard (`features/k3s/README.md`, "Metadata guard"); the v1.36.3 tree differs only
in `k3s.pin`.

**The builder.** One arm64 OrbStack machine for all four builds. `orb create --arch amd64 …` does not work on this
Mac (OrbStack 2.2.3: every amd64 machine — ubuntu resolute, noble, debian — fails with *starting the container
failed*; Rosetta emulation is broken for Docker containers too, `exec format error`). Running the whole builder
container as amd64 under qemu-user (`podman run --platform linux/amd64`) does not work either:
`setup_namespace`'s `unshare` fails with *Invalid argument* (qemu-user is multi-threaded) and with `--privileged`
`fake_xattr` fails with *clone: Function not implemented*. What works, and is how Garden Linux cross-builds:
the **arm64** builder container, which builds an `-amd64` flavor with mmdebstrap `--arch amd64`, and a
qemu-user **binfmt** handler for the amd64 chroot steps.

```sh
orb create ubuntu gl-amd64-builder                              # arm64, Ubuntu 26.04
orb -m gl-amd64-builder sudo apt-get install -y podman rsync xz-utils qemu-user   # qemu-user WITHOUT qemu-user-binfmt
orb -m gl-amd64-builder bash -c 'echo "$USER:100000:65536" | sudo tee -a /etc/subuid /etc/subgid; podman system migrate'
# the builder image must be the arm64 one (a --platform linux/amd64 pull re-points the tag):
orb -m gl-amd64-builder podman pull --platform linux/arm64 ghcr.io/gardenlinux/builder:98ee0d480844b2d041524841bfdbbb4007d32248
```

**binfmt_misc is shared by all OrbStack machines** (one kernel; an entry registered in one machine is listed in
every other). So the amd64 handler is registered under its own name only for the build and removed afterwards;
`qemu-user-binfmt` would register it permanently for every machine:

```sh
# in the machine: register (F = the interpreter is opened now, so it works inside the build container's chroot)
sed 's/^:qemu-x86_64:/:glamd64-qemu-x86_64:/' /usr/share/qemu/binfmt.d/qemu-x86_64.conf | sudo tee /proc/sys/fs/binfmt_misc/register
# ... builds ...
echo -1 | sudo tee /proc/sys/fs/binfmt_misc/glamd64-qemu-x86_64      # remove
```

**The builds.** Copy this directory into the machine (a VM-local path, not virtiofs), make the dev certs ONCE and
share them: both builds of a flavor must carry the same `oci-sign`/secure-boot certs, or the v1.36.4 UKI is not
an update of the v1.36.3 node.

```sh
rsync -a --exclude .build /Users/…/components/gardenlinux/ ~/gl/v1.36.4/
cd ~/gl/v1.36.4 && ./cert/build oci-sign.crt secureboot.pk.auth secureboot.null.pk.auth secureboot.kek.auth secureboot.db.auth  # 55 s
rsync -a ~/gl/v1.36.4/ ~/gl/v1.36.3/ && (cd ~/gl/v1.36.3 && hack/k3s-pin.sh update v1.36.3+k3s1)
O="--memory 4G --security-opt seccomp=unconfined --security-opt apparmor=unconfined --security-opt label=disable --read-only"
(cd ~/gl/v1.36.4 && ./build --container-run-opts "$O" hcloud-k3s_prod_usi-amd64)   # and -arm64; the same in ~/gl/v1.36.3
# → .build/hcloud-k3s_prod_usi-<arch>-2150.6.0-local.{raw,uki,esp.tar,tar,manifest,release}  ("local": the copy is no git tree)
```

| build (from scratch, incl. bootstrap) | wall time | parallel with |
|---|---|---|
| `hcloud-k3s_prod_usi-amd64`, v1.36.3 / v1.36.4 (chroot under qemu-user) | 488 s / 505 s | each other |
| `hcloud-k3s_prod_usi-arm64`, v1.36.3 / v1.36.4 (native) | 136 s / 135 s | each other |

All four in 10 min 41 s. Every build logs `k3s version v1.36.x+k3s1` from `exec.config` (the binary runs, under
binfmt for amd64) and the three `metadata-guard.service` symlinks. Artifacts (sizes in bytes):

| artifact | size | sha256 |
|---|---|---|
| `gl-k3s-v1.36.3-amd64.raw` | 274 726 912 | `057dcbc8d79af9a9e80e14a60d6745acddb6307a4bf4fe3880b2747a04fe8d4b` |
| `gl-k3s-v1.36.4-amd64.raw` | 273 678 336 | `890deb51611a4902bcd3559b9b49e60ae5e0126e49e769c0eaf7d330b5af83e6` |
| `gl-k3s-v1.36.4-amd64.uki` (the update artifact) | 269 002 752 | `058657b4852741681338cce708f9156d42495e4af0143e23bbb57af16965684b` |
| `gl-k3s-v1.36.3-arm64.raw` | 281 018 368 | `c9cbee5c4412c8701ca67201d732f4a035305c03d626ecdb048571135dffbe7b` |
| `gl-k3s-v1.36.4-arm64.raw` | 279 969 792 | `7faa5b8f8294cbc13b079af6949d56d4fd3f17b00cd30efc0550248c28020f8c` |
| `gl-k3s-v1.36.4-arm64.uki` (the update artifact) | 274 859 008 | `058bd3213f002e540a0ef81f1ee14a5e594dca04c8a3c64f0770ba7598fbf5b2` |

They are kept outside git on the build Mac, `~/Developer/gl-k3s-images/2026-09-27/` (with the v1.36.3 UKIs,
manifests, build logs and `SHA256SUMS`); the builder machine keeps the trees and the certs in `~/gl/`. A raw
compresses only to ~93 % with xz (the root is an EROFS inside the UKI), so compression buys little.

**The upload.** [hcloud-upload-image](https://github.com/apricote/hcloud-upload-image) v1.5.0, the release's
`hcloud-upload-image_Darwin_arm64.tar.gz` checked against its `hcloud-upload-image_1.5.0_checksums.txt`.
`--server-type` instead of `--architecture` picks the smallest disk, because a snapshot's `disk_size` is the
temporary server's disk and a server needs at least that much: 40 GB (cpx12, cax11) fits every type.

```sh
HCLOUD_TOKEN=<test project, read-write> hcloud-upload-image upload --image-path gl-k3s-v1.36.3-amd64.raw.xz --compression xz \
  --server-type cpx12 --location fsn1 \
  --description "TEST image (not for production): Garden Linux 2150.6.0 hcloud-k3s_prod_usi-amd64, k3s v1.36.3+k3s1, local build 2026-09-27, dev certs" \
  --labels "$(hack/k3s-image-labels.sh labels amd64 v1.36.3+k3s1),gl-build=local-20260927,test-image=true"
# arm64: the same with gl-k3s-v1.36.3-arm64.raw.xz, --server-type cax11, `labels arm64 v1.36.3+k3s1`
```

| snapshot in the test project | id | arch | image size | disk | upload |
|---|---|---|---|---|---|
| `hcloud-k3s_prod_usi-amd64`, k3s v1.36.3+k3s1 | **436600684** | x86 | 0.25 GB | 40 GB | 191 s |
| `hcloud-k3s_prod_usi-arm64`, k3s v1.36.3+k3s1 | **436601069** | arm | 0.24 GB | 40 GB | 163 s |

Labels (the k3s scheme above; relabeled 2026-09-27 from the first upload's shared
`gardener.cloud/image-name=gardenlinux-k3s-usi-2150.6.0` and `gl-k3s=v1.36.3`, which the management CLI refuses):
`gardener.cloud/image-name=gl-k3s-v1.36.3-amd64` and `…-arm64`, `gl-k3s=v1.36.3-k3s1`, `gl-flavor=<cname>`,
`gl-build=local-20260927`, `test-image=true` (and the uploader's `apricote.de/created-by`). The API shows
`os_flavor: ubuntu`, inherited from the uploader's temporary server; nothing reads it. **No `caph-image-name`
label yet**: with `caph-image-name=gl-k3s-v1.36.3` the ClusterClass (`imageFamily` `gl-k3s`) would pick these
test images up. Add it deliberately (`hcloud image add-label <id> caph-image-name=gl-k3s-v1.36.3`) when a run
should use them. The uploader's temporary server and SSH key were gone after each run.

**Snapshots are per project.** They exist only in the test project. The owner's real project needs its own upload of the
same `.raw.xz` (same command, that project's token), and so does every other project.

**Smoke test** (one server per snapshot in fsn1, deleted afterwards): a throwaway SSH key, this user data, then
`test/k3s-node-test.sh --host <ip> --key <key>` (checks `image,1,guard,2,3`):

```yaml
#cloud-config
write_files:
  - path: /etc/rancher/k3s/config.yaml
    permissions: "0600"
    content: |
      token: <random>
      write-kubeconfig-mode: "0600"
runcmd:
  - [touch, /var/lib/glsnap-cloud-init-marker]
  - [k3s-role, server, --now]
```

| row | amd64 on cpx22 (80 GB) | arm64 on cax11 (40 GB) |
|---|---|---|
| boots UEFI (`bootctl`: systemd-boot 259.7, entry `…-2150.6.0.efi`, Secure Boot unsupported) | PASS | PASS |
| SSH after `server create` | 31 s | 31 s |
| cloud-init `done`, `DataSourceHetzner`, `cloud-id` hetzner, marker written | PASS | PASS |
| `k3s-role show` = `k3s`; k3s v1.36.3+k3s1 | PASS | PASS |
| node Ready | PASS (< 65 s after create) | PASS (< 55 s after create) |
| `vgs`: `vg0` (ESP 4G + `VAR` 24G + rest) | PASS, 48.3 GiB | PASS, 10.1 GiB |
| `local-lvm-thin` the only default StorageClass; LocalPV-LVM running | PASS | PASS |
| a 1Gi PVC binds (a thin LV in `vg0`), writing 2Gi stops at the cap | PASS (16 s) | PASS (8 s) |
| metadata service from the host (`instance-id`) | PASS | PASS |
| metadata guard: a pod times out on 169.254.169.254 and reaches the API server | PASS | PASS |
| DNS: three Hetzner recursors, `getent hosts github.com` | PASS | PASS |
| reboot: Ready again, Secret, PVC data, root key and the guard rule survive | PASS (SSH 42 s) | PASS (SSH 33 s) |
| `k3s-node-test.sh` total | 20/20 PASS, 2 min 38 s | 20/20 PASS, 2 min 27 s |

Cost of the whole run: four servers for a few minutes each, billed as started hours (gross, fsn1): upload
cpx12 €0.0219 + cax11 €0.0114, smoke cpx22 €0.0371 + cax11 €0.0114 ≈ **€0.08**; the two snapshots keep costing
0.49 GB × €0.0170 ≈ **€0.01 per month**.

## Boot-test checklist — gate: "a GL server on hcloud runs our cloud-init payload"

Boot a CPX server from the snapshot. The `--user-data` script must write a marker file **and
`systemctl enable --now ssh.service`** — the gardener_prod preset ships sshd (and containerd)
disabled; on real nodes gardener-node-agent enables them, on a standalone test your user-data
must (it runs as root via cloud-init, so no chicken-and-egg). Then verify:

1. **Datasource:** `cloud-init status --long` clean; `cloud-id` = `hetzner`;
   `/run/cloud-init/ds-identify.log` shows Hetzner found via DMI.
2. **user_data executed:** the marker file exists (proxy for Gardener's OSC provision script).
3. **Networking:** public IPv4 up via networkd DHCP (`networkctl status`); then
   `hcloud server attach-to-network` (lab!) → private NIC gets DHCP lease *without* reboot
   (the 2026-07-06 incident class check); `resolvectl` shows exactly the 3 Hetzner recursors.
4. **Carry-overs:** `sysctl fs.inotify.max_user_instances` = 8192;
   `containerd --version` = 2.2.5 (service disabled by preset — gardener enables it);
   apparmor: `/etc/apparmor.d/runc` **exists on GL too**; the kill-denial mitigation is
   containerd ≥ 1.7.24-line behavior, i.e. 2.2.x. Verify kill/exec on a pod in the drills,
   not profile absence here.
5. **USI variant on a CPX (UEFI):** boots EFI-only; `bootctl status` sane;
   `/etc/gardenlinux/usirepo.conf` present (TODO ref), `/etc/gardenlinux/oci_signing_key.pem` baked.
6. **Console:** hcloud web console (noVNC) shows getty (console=tty0 last).

## Automated test suite (run on EVERY image update — GL releases every 2–5 weeks)

```sh
# throwaway-resource scenarios: basic, volume, hot-attach, container(kill-denial), reboot, private-nat
HCLOUD_TOKEN=<lab> ./test/run-tests.sh --image <snapshot-id> --arch x86   # and --arch arm
# grandfathered-pet rebuild (BIOS on CX / arm64 on CAX; price-safe, never delete/change_type):
HCLOUD_TOKEN=<lab> ./test/rebuild-pet-test.sh --server <id> --image <snapshot-id> --power-off-after
```

Everything the suite creates is `gl-test-`-prefixed + run-labeled and swept on exit; cost per
run is cents (2-4 cpx22 for ~15 min + a 10G volume). Platform facts the scenarios encode
(private-net DHCP gives no DNS/route/metadata; fully-private = no metadata at all; GL private
NIC is `enp7s0` not `ens10`; usi `/` immutable + `/root` tmpfs) are documented in the
landscape repo's implementation log. The suite is not wired into CI (labs cost money; the root
CI only syntax-checks the builder scripts) — run it by hand on every image update.
