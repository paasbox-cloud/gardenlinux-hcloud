# Feature: k3s

A **k3s node** from the image: `/usr/bin/k3s` is part of the OS, the cluster's state lives in the
persistent `/var`, and local volumes are logical volumes in the volume group `vg0` (OpenEBS
LocalPV-LVM). The consumer is the single- and few-node platform of `components/saas-platform` (brief:
`components/saas-platform/docs/garden-linux-k3s.md`).

It is an **alternative to the `gardener` element, never a companion**: `info.yaml` excludes
`gardener`, so the builder refuses a flavor that names both (`AssertionError: excluding explicitly
included feature gardener`). k3s brings its own containerd; the gardener element installs and
configures the distribution's containerd for gardener-node-agent. Two runtimes on one node is the drift
this OS exists to avoid, so there are two images, not one image with a switch.

## Flavors

| cname | Boot | In-place | Use |
|---|---|---|---|
| `hcloud-k3s_prod_usi-amd64` | EFI-only (USI/UKI) | **yes** (`gardenlinux-update`, A/B) | k3s on CPX/CCX |
| `hcloud-k3s_prod_usi-arm64` | EFI-only (USI/UKI) | **yes** | k3s on CAX; ownpaas' vz backend on a Mac |
| `baremetal-robot-k3s_prod-amd64` (builder name `baremetal-k3s-robot_prod-amd64`) | BIOS+UEFI | no | k3s on a Robot box, installed through installimage |

**No classic `hcloud-k3s_prod-*`.** The classic flavor has one reason to exist: BIOS-only CX types.
But it has no in-place update, so on a classic node a new OS — and with it a new k3s — means
`hcloud server rebuild`, which rewrites the disk and destroys `vg0` with every local volume in it. The
brief's two goals are image-based upgrades and volumes on the node's own disk; a classic k3s node can
have only one of them at a time. Every hcloud type the platform uses (CPX, CCX, CAX) boots UEFI, so the
`_usi` flavors cover them. If a BIOS-only box is ever needed, the feature itself builds classic
(`hcloud-k3s_prod-amd64` resolves and needs no change); what it lacks is the `vg0` partition, since
`initrd.include/etc/repart.d` only takes effect in the `_usi` initrd (see *Disk layout*).

## What is in the image (read-only, updated with it)

| What | Where | Why |
|---|---|---|
| k3s, pinned | `/usr/bin/k3s` + `kubectl`, `crictl`, `ctr` symlinks | `k3s.pin` = the stack's `runtime.k3s` pin (`hack/k3s-pin.sh check`). Verified three ways at build — see *How k3s gets into the image*. |
| the two roles, **disabled** | `/usr/lib/systemd/system/k3s.service`, `k3s-agent.service` | The role comes from provisioning. A preset (`/etc/systemd/system-preset/00-k3s.preset`) keeps a first-boot `preset-all` from enabling them, and `exec.config` fails the build if either is enabled. They `Conflict=` each other. |
| `k3s-role` | `/usr/sbin/k3s-role server\|agent\|none\|show [--now]` | The one call provisioning makes: disables the other role, enables this one, refuses an agent without `server:`/`token:`. |
| k3s defaults | `/etc/rancher/k3s/config.yaml.d/00-image.yaml`; `k3s.service`'s `ExecStart` | The drop-in holds only `data-dir: /var/lib/rancher/k3s` (stated, it is the default), because server **and** agent read it and an agent exits on a server-only key (*flag provided but not defined: -disable* — measured: the first version had `disable+:` there and no agent ever started). So local-path is off by a server argument, `k3s server --disable=local-storage`, which adds to — not replaces — a node's own `disable: [traefik]` in `config.yaml`. k3s reads `config.yaml` first and the drop-ins after it; a later scalar replaces an earlier one. |
| bootstrap manifests | `/usr/share/k3s/manifests/image-*.yaml` | The lvm-localpv **HelmChart** (chart 1.10.1, values = `pool-manager/examples/storage/localpv-lvm/values.yaml`, checked by `hack/k3s-pin.sh check`) and the StorageClasses: **`local-lvm-thin`, the only default**, and `local-lvm-thick`. `ExecStartPre=/usr/libexec/k3s/sync-manifests` copies them into `/var/lib/rancher/k3s/server/manifests/` on **every** start, so an image update (or a rollback) updates them; it removes an `image-*.yaml` the image no longer ships and leaves every other file alone. Opt out of one with k3s' own `<name>.skip`. Everything else — CNPG, the controller, observability, Flux — comes from Flux, not the image. |
| kernel prerequisites | `/etc/modules-load.d/k3s.conf`, `/etc/sysctl.d/90-k3s.conf` | `overlay`, `br_netfilter`, `nf_conntrack` at boot, and **`dm_thin_pool`, `dm_snapshot`** — LocalPV-LVM runs `lvcreate` inside its container, which has no `/lib/modules`, so lvm cannot load the thin target itself and the first thin PVC fails with *thin: Required device-mapper target(s) not detected* (found on this image's first boot); the host must have it loaded; `ip_forward`, IPv6 forwarding, `bridge-nf-call-ip{,6}tables`. `exec.config` fails the build if the kernel lacks any module k3s needs (overlay, br_netfilter, vxlan, the xt_/nft_ modules, dm_thin_pool, …). cgroup v2 is Garden Linux's default. |
| packet filter | `iptables` (Garden Linux default: **iptables-nft** 1.8.11), `conntrack`, `ethtool`, `socat` | k3s prefers the host's iptables when there is one. The gardener element switches to iptables-legacy for Cilium; flannel has no such need. `ipset` is not in the Garden Linux repository — k3s carries its own. |
| LSM | `apparmor` + `security=apparmor` (`cmdline.d/90-lsm.cfg`) | As on the gardener element. `_selinux` is excluded: there is no k3s SELinux policy for this OS. containerd refuses containers when AppArmor is on and `apparmor_parser` is missing. |
| LVM | `lvm2`, `thin-provisioning-tools`, `dmeventd`, `xfsprogs`; `/etc/lvm/lvmlocal.conf` | The dedicated pool's policy: thin pool autoextend at 80 % by 20 %, monitoring on (`exec.config` checks `lvmconfig` resolves it). `k3s-thinpool-monitor.timer` registers the CSI-created thin pool with dmeventd — the CSI creates it from inside its container, where it is never monitored (same fix as nodepool-core's). |
| `vg0` | `k3s-vg0.service` → `/usr/libexec/k3s/setup-vg0` | Enabled, ordered before both roles. Idempotent: `pvcreate`/`vgcreate` only when `vg0` is absent and the partition labelled `vg0` carries no signature at all; any other signature is a refusal, never a format. `pvresize` when the partition grew. No partition and no `vg0` → a message and exit 0: k3s runs, LVM volumes stay Pending. |
| shutdown | `k3s-stop-pods.service` → `/usr/libexec/k3s/stop-pods` | The role units use `KillMode=process` so that restarting k3s leaves the workloads running. At shutdown that left the containers to systemd-shutdown's final sweep, which waits 90 s for any process ignoring SIGTERM — measured: LocalPV-LVM's `lvm-driver` (a container PID 1 without a handler) held every agent reboot for 90 s. This unit stops right after k3s and gives `kubepods.slice` SIGTERM, 10 s, then `cgroup.kill`: the reboot went from ~100 s to 20 s. A `systemctl restart k3s` does not touch it. |
| metadata guard | `metadata-guard.service`, **enabled** | One iptables rule in the `raw` table drops every packet to `169.254.169.254` that passes PREROUTING, i.e. every packet from a pod; the host keeps its access. Before both roles and `RequiredBy` both: no k3s without the rule. See *Metadata guard* below. |
| firewall | **excluded** | As on the gardener element. The upstream `firewall` element's nftables table would sit beside the rules k3s, kube-proxy and flannel own. |

## Storage: the image's LVM classes, and hcloud volumes next to them

The image brings two StorageClasses, both `local.csi.openebs.io` (OpenEBS LocalPV-LVM) in `vg0`, so
both **node-local** — a volume lives on the disk of the node that first ran its pod and never moves:

| class | default | what it is |
|---|---|---|
| `local-lvm-thin` | **yes, the only one** | a thin LV; its size is a hard cap, snapshots are cheap |
| `local-lvm-thick` | no | extents reserved up front |

On Hetzner Cloud (and on ownpaas, where vz serves hcloud volumes over NVMe/TCP, and KubeVirt as LVM
PVCs) a cluster can add **network volumes** with Hetzner's
[hcloud-csi-driver](https://github.com/hetznercloud/csi-driver) (`runtime.hcloud-csi` in
the stack's version pins, v2.21.2): class `hcloud-volumes`, provisioner `csi.hetzner.cloud`, volumes of
**at least 10 GB** that detach from a lost node and attach to another one (hcloud servers only — a
Robot box cannot attach them). Its chart creates that class **marked default** unless told otherwise
(`storageClasses[].defaultStorageClass: true` in the chart's `values.yaml`; the release manifest
`deploy/kubernetes/hcloud-csi.yml` hard-codes `is-default-class: "true"`). With two defaults,
Kubernetes gives a PVC without `storageClassName` to the **most recently created** default class — so
installing the driver would silently move every unqualified PVC from the local class to network
volumes. Install it with the Helm chart and turn the default off (keys checked against the chart at
v2.21.2, `chart/values.yaml` and `chart/templates/core/storageclass.yaml`):

```yaml
# helm upgrade --install hcloud-csi hcloud/hcloud-csi -n kube-system --version 2.21.2 -f <this file>
storageClasses:
  - name: hcloud-volumes
    defaultStorageClass: false
    reclaimPolicy: Delete
```

(Not the release manifest: patching its annotation afterwards is undone by the next `kubectl apply`.)
`kubectl get sc` must then show exactly one `(default)`: `local-lvm-thin`. The image does not enforce
this — no HelmChartConfig for hcloud-csi ships in `/usr/share/k3s/manifests` — so it is the installer's
job, and the check belongs in whatever installs the driver.

Which class for what:

| use | class | why |
|---|---|---|
| replicated databases (CNPG), caches, anything IOPS-bound | `local-lvm-thin` | local NVMe speed; the application's own replication (CNPG's standbys) is what survives a node, not the volume |
| single-replica state that must survive losing or moving its node | `hcloud-volumes` (name it in the PVC) | the volume re-attaches wherever the pod is rescheduled |

## How k3s gets into the image

`exec.config` runs inside the build chroot, and the chroot shares the build container's network — the
package installation a few steps earlier happens in the same chroot. So the release is downloaded
there, not staged by a pre-build step every local build and every CI job would have to remember:

1. `k3s.pin` holds the version and the sha256 of both architectures' binaries. It is the trust anchor.
2. The release's own `sha256sum-<arch>.txt` must list the same sum for the asset (`k3s`, `k3s-arm64`)
   — a re-published asset is caught before its bytes are fetched.
3. The downloaded binary must match (`sha256sum --check --strict`), and `k3s --version` must report the
   pinned version (an amd64 binary on an arm64 builder runs through binfmt).

A build therefore needs **github.com** as well as packages.gardenlinux.io. Re-pinning is
`hack/k3s-pin.sh update <version>` (writes all three lines); the monorepo CI runs
`hack/k3s-pin.sh check`, which fails while `k3s.pin` and the stack's `runtime.k3s` pin differ,
so a Renovate bump of `runtime.k3s` stays red until the image follows it in the same change.

## Disk layout

### `_usi` (hcloud): `/var` fixed, the rest is `vg0`

The root is an EROFS inside the UKI on the ESP; `/var` is its own ext4 partition, and `/etc` is an
overlay whose upper layer is `/var/etc.overlay` (the vendored `_usi` and `_nocrypt` layout).
`gardenlinux-update` writes a new UKI to the ESP and leaves `/var` alone, so **`/var` — k3s' datastore,
containerd's images, the node password, and via the `/etc` overlay `config.yaml` and the enabled role —
persists across image updates and rollbacks.** `test/k3s-node-test.sh` checks this is the layout a
booted node actually has (not only that `/var` exists).

systemd-repart lays the disk out in the initrd on first boot. This feature adds, only to the k3s
flavors' initrd:

| file | effect |
|---|---|
| `repart.d/00-efi.conf.d/50-k3s.conf` | ESP `SizeMaxBytes=4G` — otherwise the ESP (weight 1) and `vg0` (weight 1) would split the remainder evenly |
| `repart.d/10-var.conf.d/50-k3s.conf` | `/var` `SizeMaxBytes=24G` — its weight (15) fills it first, up to the cap |
| `repart.d/20-vg0.conf` | a Linux LVM partition labelled `vg0`, weight 1, no maximum — everything after `/var` |

Drop-ins rather than edits: the vendored definitions stay verbatim, and the gardener flavors' initrd is
unchanged. Measured with Garden Linux's own systemd-repart (259.7): 40G → ESP 4G + `/var` 24G + `vg0`
12G; 80G → 4 + 24 + 52; 160G → 4 + 24 + 132; below ~30G `/var` takes most of the disk. repart never
shrinks a partition, and `vg0` is last, so a grown disk grows `vg0` (repart on the next boot, then
`pvresize` in `k3s-vg0.service`).

### Robot: installimage's `vg0`

installimage lays down `SWRAID 1` + `PART lvm vg0 all` + a sized root LV (`pool-manager`'s
`DiskLayout`), and the rest of `vg0` is free — exactly what LocalPV-LVM provisions into. The
`/var/lib/rancher` state lives on the root LV. `k3s-vg0.service` finds `vg0` and only activates it; the
repart files are inert here (the classic initrd has no systemd-repart). A Robot box written with `dd`
of the `.raw` has no `vg0` — the node runs, LVM volumes stay Pending. See `features/robot/README.md`
for the installimage path and its boot caveats; they apply unchanged.

## Provisioning: one role per node

The image never starts k3s on its own. Provisioning writes `/etc/rancher/k3s/config.yaml` and calls
`k3s-role`.

**hcloud** — cloud-init user data (the `Hetzner` datasource; `NoCloud` works the same for local VMs):

```yaml
#cloud-config
write_files:
  - path: /etc/rancher/k3s/config.yaml
    permissions: "0600"
    content: |
      token: <shared secret>          # servers and agents share it; with the snapshots, the whole restore material
      tls-san: [<public ip or name>]
      cluster-init: true              # embedded etcd, also on a single node (see "Datastore" below)
      etcd-snapshot-schedule-cron: "0 */6 * * *"
      etcd-snapshot-retention: 28
      etcd-s3: true
      etcd-s3-endpoint: <s3 endpoint, e.g. fsn1.your-objectstorage.com>
      etcd-s3-bucket: <bucket>
      etcd-s3-folder: <cluster name>
      etcd-s3-access-key: <access key>
      etcd-s3-secret-key: <secret key>
      # further servers of the cluster: server: https://<first>:6443 (and no cluster-init)
runcmd:
  - [k3s-role, server, --now]         # or: [k3s-role, agent, --now] with server: + token: above
```

**Datastore: embedded etcd with S3 snapshots, also on one node.** The image leaves the choice to
`config.yaml`: without `cluster-init`, k3s uses SQLite, which takes no snapshots, so a lost disk loses
the cluster. With `cluster-init: true` and the `etcd-s3` keys above, k3s snapshots etcd on the schedule
and uploads each snapshot to S3; the node's **token** encrypts the bootstrap data in a snapshot, so the
token plus the bucket is everything a restore needs. It costs 25–70 MiB more memory than SQLite
(measured by the saas-platform layer), and it is the same datastore a second and third server later join
(`server:` instead of `cluster-init`). Restore onto a fresh node from this image, with the same
`config.yaml` (same token):

```sh
k3s server --cluster-reset --cluster-reset-restore-path=<snapshot name> \
  --etcd-s3 --etcd-s3-endpoint=… --etcd-s3-bucket=… --etcd-s3-folder=… \
  --etcd-s3-access-key=… --etcd-s3-secret-key=…
k3s-role server --now          # then start normally
```

`k3s etcd-snapshot ls` lists the snapshots (local and S3); take one by hand before a k3s **minor**
upgrade (`k3s etcd-snapshot save`), because that step cannot be rolled back by the A/B slot (see 5).
Persistent volumes are not in the snapshot: LVM volumes are backed up by the application (e.g.
CloudNativePG to S3) or live on `hcloud-volumes`.

**Robot** — installimage's post-install runs in the chroot of the new root, where nothing may be
started: write the same `config.yaml`, then `k3s-role server` (or `agent`) **without** `--now`.

**Several nodes on a private network** (hcloud network, a vSwitch): set `node-ip:` to the node's
private address **and** `flannel-iface:` to the private NIC (`enp7s0` on hcloud). `node-ip` alone is
not enough — flannel still picks the default-route interface as its VXLAN endpoint, and the overlay
then runs over the public side (measured: with only `node-ip`, pod-to-pod traffic between two nodes
failed where the public side did not carry it).

**Do not edit the image's own files in `/etc`** (`config.yaml.d/00-image.yaml`, the sshd drop-in, …) on
a `_usi` node: `/etc` is an overlay, and a file changed on the node lives in the upper layer on `/var`,
where it shadows every later image's version of that file for good. Put node settings in
`config.yaml` or in a drop-in of your own (`config.yaml.d/50-*.yaml`, read after the image's).

## Metadata guard

Hetzner's metadata service serves a server's **user data** at `http://169.254.169.254/hetzner/v1/userdata`
for the server's whole life. For a first server that is the k3s token (and, under cluster-api-k3s, the
cluster's CA private keys); for an agent, the join token. Any pod reaches it through the node's forwarding
and NAT. So the image ships and enables `metadata-guard.service`:

```sh
iptables -w -t raw -C PREROUTING -d 169.254.169.254/32 -m comment --comment metadata-guard -j DROP 2>/dev/null ||
  iptables -w -t raw -I PREROUTING -d 169.254.169.254/32 -m comment --comment metadata-guard -j DROP
```

- **No source match.** A pod's packet arrives on `cni0` and passes PREROUTING; the host's own packets
  (hostNetwork pods included) leave through OUTPUT and never do. So the rule needs no pod CIDR. The `raw`
  table is before conntrack, and neither k3s, kube-proxy, flannel nor kube-router's policy controller write to
  it. DROP, because REJECT is not valid in `raw`: a pod's request times out.
- **Fail closed.** `Before=` and `RequiredBy=` both `k3s.service` and `k3s-agent.service`: systemd starts it
  before either role on every boot, and a role does not start without it. `exec.config` fails the build when
  either `.requires` link is missing. Stopping the unit leaves the rule in place.
- **Every provisioning path is covered** — cloud-init with `k3s-role`, the ClusterClass, a pool machine, by
  hand — from the first boot, because the rule is generic (no CIDR, no cluster data).
- **The ClusterClass' copy** (the management cluster's ClusterClass writes `/etc/systemd/system/metadata-guard.service`)
  has the same name and rule: `/etc` overrides `/usr/lib`, and `-C` makes the rule idempotent, so the two
  never add up. It stays for other images.
- **What needs the metadata service from the pod network** must run with `hostNetwork: true`: the hcloud CSI
  node plugin takes its server ID from `/hetzner/v1/metadata/instance-id` with no override.
  The hcloud CCM is hostNetwork already.
- **Not covered:** hostNetwork and privileged pods still read the user data (admission has to forbid them where
  tenants run pods), and IPv6 (the metadata service has only the IPv4 link-local address).

`test/k3s-node-test.sh --checks image,guard` checks it: the unit is enabled, active, required by both roles and
the rule is in place (check `image`); the host gets an answer from the metadata service and a pod gets none
(check `guard`; where there is no metadata service at all, e.g. QEMU, only the pod half is meaningful and the
check says so).

## SSH

A k3s node is not a Gardener node: nobody enables sshd for it later, and it is a long-lived box an
operator has to reach. So sshd stays **enabled** (the gardener element's `disable ssh.service` preset
is not part of these flavors), with the conventions the hcloud and robot elements already set:
**key-only root** (`PermitRootLogin prohibit-password`, `AuthenticationMethods publickey`, no
passwords anywhere), sshguard on iptables.

One addition for `_usi`, where `/root` is a tmpfs and the key cloud-init delivers (once per instance)
would be gone after the first reboot: `k3s-persist-root-keys.service` copies real key lines from
`/root/.ssh/authorized_keys` to `/etc/ssh/authorized_keys.d/root` (persistent, in the `/etc` overlay),
and `sshd_config.d/50-k3s-authorized-keys.conf` makes sshd read it. Keys are only ever added; revoking
one means editing that file.

## What is shared with the gardener flavors, and why nothing interferes

The **platform** half is shared unchanged: `hcloud` (datasource list `Hetzner, NoCloud, None`;
networking by systemd-networkd DHCP, not cloud-init; the ≤3 Hetzner recursors DNS trim; the console
line; inotify sysctls; the sshd fixes; `usirepo.conf`; the rpcbind mask — a no-op here, nothing
installs rpcbind) and `robot` (full kernel, LVM/mdadm/extlinux for installimage, the same trims). The
k3s role needs none of them changed: pods resolve through CoreDNS, which forwards to the host's
resolv.conf, and kubelet's `resolvConf` limit is exactly what the DNS trim protects.

The **element** half is exclusive: `k3s` or `gardener`. Nothing in `features/k3s` is referenced by a
gardener flavor's closure (`parse_features` lists it only for the k3s cnames), its initrd additions are
drop-ins that exist only in the k3s flavors' initrd, and no vendored or shared file was edited for it.

## Testing

`test/k3s-qemu.sh <raw>` boots a flavor under QEMU (KVM when available, TCG otherwise) as a
single-node server on a 40G disk, provisioned like an hcloud server through a NoCloud seed, and runs
`test/k3s-node-test.sh` against it. The node test needs only SSH to a server node, so it runs just as
well against a vz VM, an hcloud server or a Robot box. Checks, in the brief's order:

| # | Check | How | Result (2026-09-23, `hcloud-k3s_prod_usi-arm64`, Apple vz on an M3 Ultra) |
|---|---|---|---|
| image | pinned k3s + symlinks; exactly one role enabled, by provisioning; `k3s check-config`; cgroup v2, modules incl. `dm_thin_pool`, sysctls, AppArmor; `/var` is the partition `VAR` and `/etc`'s upper layer is in it (`_usi`); `vg0` active; thin-pool policy resolves | `k3s-node-test.sh` | pass |
| 1 | k3s Ready; `kubectl get sc` shows `local-lvm-thin` as the only default; LocalPV-LVM running | `k3s-node-test.sh` | pass (Ready in < 1 min, LocalPV-LVM ready 1–2.5 min after) |
| 2 | a 1Gi PVC is a 1Gi thin LV in `vg0`; writing 2Gi into it fails with ENOSPC | `k3s-node-test.sh` | pass (`dd` stops at 957 MB; the thin pool autoextended 1.00g → 1.22g, monitored) |
| 3 | reboot: Ready again, a Secret, a Deployment and the PVC's data survived | `k3s-node-test.sh` | pass (15/15 on a fresh node) |
| 4 | update to an image with a newer k3s patch (v1.36.3+k3s1 → v1.36.4+k3s1) | `test/k3s-update-test.sh` (first done by hand, below) | pass — new UKI on the ESP, reboot: node on v1.36.4; LVs, PVs, Postgres rows, file sha256, Secret unchanged (see *In-place update vs. replacing the machine*) |
| 5 | rollback to the other slot | `test/k3s-update-test.sh` (first done by hand, below) | pass — default entry back to the old UKI: v1.36.3 again, rows written under v1.36.4 still there |
| 6 | server + agent, one node at a time, app serving throughout | by hand, below | pass — 2 replicas + PDB, NodePort polled on both nodes every ~0.75 s: 247 samples, never both down |

On real Hetzner Cloud (2026-09-27, the test-project snapshots of both `_usi` flavors with k3s v1.36.3+k3s1, one
cpx22 and one cax11): checks image, 1, **guard**, 2 and 3 of `test/k3s-node-test.sh` pass 20/20 on both
(`../../README.md`, "Building the k3s snapshots locally"). Checks 4–5 on Hetzner are still open; the v1.36.4 UKIs
they need were built alongside.

Checks 4–6 ran (and `test/k3s-update-test.sh` runs) without the OCI half of `gardenlinux-update` (below): the new UKI was copied onto the
ESP — which is what `gardenlinux-update` writes after it has pulled and verified an artifact — and
selected with `bootctl set-default`. Under QEMU/TCG (no KVM in an OrbStack machine) the node boots and
check "image" passes, but LocalPV-LVM's provisioning times out on an emulated CPU; use KVM or vz for
checks 1–3.

### 4 — `gardenlinux-update` to a newer k3s patch

The full path needs: two builds of the same `_usi` flavor that differ in `k3s.pin` (e.g. v1.36.4+k3s1 and the next
`+k3s` patch of 1.36), **signed with the key baked into the running image** (`cert/oci-sign.*`), and an
OCI repository `gardenlinux-update` can reach — `/etc/gardenlinux/usirepo.conf` names it
(`ghcr.io/paasbox-cloud/gardenlinux-hcloud`; the pipeline that publishes signed update images there is
still open, see the root README). With that in place, on a server node that passed checks 1–3:

```sh
kubectl -n k3s-image-test create secret generic before-update --from-literal=k=v
gardenlinux-update <new version>            # writes the new UKI to the ESP, next boot = new slot
systemctl reboot
# then: k3s --version is the new patch; kubectl get nodes Ready; the Secret, the Deployment and
# /data/marker from check 3 are all still there (test/k3s-node-test.sh --checks 1,3 re-checks)
```

Without the repository, the part that matters for the node — a second UKI on the ESP, `/var` and the
`/etc` overlay untouched — is exercised by hand, which is how it was measured: build the same flavor
once more with the other k3s pin (`hack/k3s-pin.sh update v1.36.3+k3s1` in a scratch copy), boot the
older one, then

```sh
scp <newer>.uki root@node:/efi/EFI/Linux/hcloud-k3s_prod_usi-arm64-2150.6.1.efi
ssh root@node 'bootctl set-default hcloud-k3s_prod_usi-arm64-2150.6.1.efi && systemctl reboot'
```

### 5 — rollback

Boot the previous UKI (systemd-boot's menu, `bootctl set-oneshot <previous entry>` for one boot, or
`bootctl set-default <previous entry>` to stay) and reboot. The
node must come back on the **old** k3s with the same state. Only within one k3s **minor**: k3s does
not support downgrading its datastore across minors, so a minor upgrade (1.36 → 1.37) is a one-way
step for the node, and the older slot is then a way back for the OS only after restoring an etcd
snapshot taken before the upgrade (`k3s etcd-snapshot save`, see "Datastore"). Pin minor upgrades to their own image release.

### 6 — several nodes

Three `hcloud-k3s_prod_usi` servers: the first with `cluster-init: true`, the others with
`server: https://<first>:6443` (or one server + two agents via `k3s-role agent`), a shared `token:`,
and an application with ≥2 replicas and a PodDisruptionBudget. One node at a time: `kubectl drain`,
`gardenlinux-update`, reboot, wait Ready, `kubectl uncordon`; the application must keep serving
throughout. Servers first, then agents: an agent must not run a newer k3s than its servers. Measured
with one server + one agent (both `hcloud-k3s_prod_usi-arm64`, private link, `flannel-iface` set),
v1.36.3 → v1.36.4: server drained, updated, back Ready in ~20 s; agent the same; the NodePort answered
on at least one node in every sample. Volumes on `local-lvm-*` are node-local — a replica's volume goes down with its node, so
the application's own replication (CNPG) is what keeps its data available, not the storage.

## In-place update vs. replacing the machine

A pool node that holds local volumes can get a new OS and a new k3s **in place**. Replacing the
machine to get them costs every local volume.

**What survives the A/B update, measured** (2026-09-24, `test/k3s-update-test.sh`,
`hcloud-k3s_prod_usi-arm64` under Apple vz, one server with `cluster-init`, 40G disk = ESP 4G + `VAR`
24G + `vg0` 12G). Two builds from the same tree, differing only in `k3s.pin` (v1.36.3+k3s1 and
v1.36.4+k3s1). Update, then rollback: 24 PASS / 0 FAIL. On both boots all of the following stayed the
same:

- `/var`, which holds etcd, the Secret and the node object with the same UID;
- `vg0`, with each thin LV and the thin pool keeping its **name and LV UUID**, so the update
  recreated none of them;
- each `LVMVolume` object, keeping its UID;
- both PVCs, still Bound to the same PVs (PVC and PV UIDs unchanged);
- the data: a 32 MiB file (same sha256) and a Postgres table (same count and digest over every
  row, including 500 rows written under v1.36.4 and read back after the rollback to v1.36.3);
- the pods, which came back on the same node.

| phase | update (v1.36.3 → v1.36.4) | rollback |
|---|---|---|
| `k3s etcd-snapshot save` (7.9 MB) | 1 s | — |
| copy the UKI (275 MB) to the ESP | 2 s | — (already there) |
| cordon + drain | 31 s | 31 s |
| reboot → SSH on the new boot | 15 s | 13 s |
| reboot → node Ready (kubelet of the new boot) | 22 s | 18 s |
| uncordon → the file pod and Postgres Ready | 18 s | 19 s |

Of the drain, 30 s is the LocalPV-LVM controller's termination grace period. Deleted one at a time,
the pods took: `lvm-localpv-controller` 31.1 s, `pg-0` 0.7 s, coredns 1.0 s, metrics-server 2.0 s.
An image without `k3s-stop-pods.service` (an earlier build, 2026-09-23) took **99 s** from reboot to
SSH. Its journal shows the pods stopping at shutdown start and the final sweep 90 s later, which is
the sweep that unit exists to end. The 4G ESP held both UKIs, with 3.8G free before the copy.

**What a replacement costs.** A new OS reaches a replaced machine only by rewriting its disk. That
means `hcloud server rebuild` on hcloud (see *Flavors*), or pool-manager's reimage through
installimage on Robot. Either one lays out `vg0` anew, and every LV in it is gone.
`../pool-manager/docs/local-storage.md` says so ("a reimage destroys the local volumes"). With the
pool's default `releasePolicy: Wipe`, releasing a box wipes it. `releasePolicy: Bind` (phase
`ReadyBound`) skips that wipe, and the node name and data survived a Machine replacement (measured
2026-09-12). But Bind hands back the **same disk with the same OS**, so it keeps the volumes only by
not delivering a new image. Nothing in this section measured a replacement; those facts come from
the documents cited.

**For a Cluster API rollout of pool machines,** a `maxSurge: 0, maxUnavailable: 1` rollout replaces
Machines. On a pool with `Wipe`, it wipes each node's local volumes, one node at a time. With `Bind`,
it cannot deliver the new image at all. The in-place path above keeps the volumes and costs one
drain plus about 20 s of reboot per node. The steps are: drain, UKI to the ESP, `set-default`,
reboot, uncordon. Upgrading pool nodes therefore means an in-place update driven per Machine, not a
Machine rollout. The application's own replication (CNPG) still covers the node being down during
its reboot. Within one k3s minor, the old slot remains the way back. Across a minor, the only way
back is the etcd snapshot taken before the update (see 5).
