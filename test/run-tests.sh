#!/usr/bin/env bash
# Garden Linux hcloud image test suite (NOTES.md records executed runs).
#
# Boots real servers from a candidate snapshot and exercises the scenarios that bit us on
# the Ubuntu image: NAT/private-net, the route race, runc
# kill-denial, volume hotplug. Designed for every image update — GL's release cadence is
# 2-5 weeks — runnable locally or from CI (needs only: hcloud CLI, jq, ssh, a lab-project
# HCLOUD_TOKEN).
#
#   HCLOUD_TOKEN=... ./run-tests.sh --image <snapshot-id> [--arch x86|arm] \
#       [--scenarios basic,volume,hot-attach,container,reboot,private-nat] [--location nbg1]
#
# Safety: everything it creates carries the gl-test- prefix + a per-run label
# (gl-test-run=<id>) and is deleted in the EXIT trap. It never touches resources it did
# not create. Grandfathered-pet rebuild tests (BIOS/ARM on real pets) are deliberately
# NOT here — see rebuild-pet-test.sh (protection handling, no auto-cleanup).
set -u -o pipefail

LOCATION=nbg1
ARCH=x86            # x86 -> cpx22 SUT, arm -> cax11 SUT
IMAGE=""            # snapshot ID (required)
SCENARIOS="basic,volume,hot-attach,container,reboot,private-nat"
NAT_IMAGE="ubuntu-24.04"   # harness box for private-nat, not the SUT
RUN_ID="$(date +%s | tail -c 6)$RANDOM"
PREFIX="gl-test"
RUN_LABEL="gl-test-run=$RUN_ID"

while [ $# -gt 0 ]; do case "$1" in
  --image) IMAGE=$2; shift 2;;
  --arch) ARCH=$2; shift 2;;
  --scenarios) SCENARIOS=$2; shift 2;;
  --location) LOCATION=$2; shift 2;;
  *) echo "unknown arg $1"; exit 2;;
esac; done
[ -n "$IMAGE" ] || { echo "--image <snapshot-id> required"; exit 2; }
[ -n "${HCLOUD_TOKEN:-}" ] || { echo "HCLOUD_TOKEN required"; exit 2; }
command -v hcloud >/dev/null && command -v jq >/dev/null || { echo "need hcloud + jq"; exit 2; }
case "$ARCH" in x86) SUT_TYPE=cpx22;; arm) SUT_TYPE=cax11;; *) echo "--arch x86|arm"; exit 2;; esac

WORK=$(mktemp -d); PASS=0; FAIL=0; RESULTS=()
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes -i "$WORK/key")
CREATED_SERVERS=(); CREATED_NETWORKS=(); CREATED_VOLUMES=(); CREATED_KEYS=()

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
check() { # check <name> <cmd...> — record pass/fail, keep going
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); RESULTS+=("PASS $name"); log "  PASS $name"
  else FAIL=$((FAIL+1)); RESULTS+=("FAIL $name"); log "  FAIL $name"; fi
}
ssh_sut() { local ip=$1; shift; ssh "${SSH_OPTS[@]}" "root@$ip" "$@"; }
# ProxyJump does NOT inherit our host-key/BatchMode options for the HOP connection — it
# reads ~/.ssh/config defaults, so the hop dies on host-key verification and every jumped
# check fails regardless of SUT state (this masqueraded as "IPv6-only servers do not
# bootstrap" for a whole day). ProxyCommand with explicit options is the reliable form.
ssh_via() { local jump=$1 ip=$2; shift 2; ssh "${SSH_OPTS[@]}" -o "ProxyCommand=ssh -i $WORK/key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -W %h:%p root@$jump" "root@$ip" "$@"; }

cleanup() {
  set +e
  log "cleanup (run $RUN_ID)"
  for s in "${CREATED_SERVERS[@]:-}"; do [ -n "$s" ] && hcloud server delete "$s" >/dev/null 2>&1; done
  for v in "${CREATED_VOLUMES[@]:-}"; do [ -n "$v" ] && { hcloud volume detach "$v" >/dev/null 2>&1; hcloud volume delete "$v" >/dev/null 2>&1; }; done
  for n in "${CREATED_NETWORKS[@]:-}"; do [ -n "$n" ] && hcloud network delete "$n" >/dev/null 2>&1; done
  for k in "${CREATED_KEYS[@]:-}"; do [ -n "$k" ] && hcloud ssh-key delete "$k" >/dev/null 2>&1; done
  # belt-and-braces: sweep anything left carrying this run's label
  hcloud server list -l "$RUN_LABEL" -o noheader -o columns=name 2>/dev/null | xargs -n1 -r hcloud server delete >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---- user-data: what Gardener's OSC provision script is a stand-in for. gardener_prod
# ships ssh/containerd disabled by preset (node-agent enables them on real nodes).
cat > "$WORK/userdata.sh" <<'EOF'
#!/bin/bash
set -e
echo "gl-boot-test $(date -u +%FT%TZ) $(hostname)" > /var/lib/gl-boot-test
systemctl enable --now ssh.service
# persist the metadata-delivered key OUTSIDE /root — on the usi variant /root is a
# tmpfs, so the cc_ssh-delivered key vanishes on reboot (cc_ssh is once-per-instance)
mkdir -p /etc/ssh/authorized_keys.d
cp /root/.ssh/authorized_keys /etc/ssh/authorized_keys.d/root
printf 'AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys.d/%%u\n' > /etc/ssh/sshd_config.d/70-gl-test-keys.conf
# images built before the exec.config Include-fix (2026-07-07) ignore sshd_config.d entirely
grep -q '^Include /etc/ssh/sshd_config.d' /etc/ssh/sshd_config || \
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
systemctl reload ssh.service || true
EOF

ssh-keygen -q -t ed25519 -N '' -f "$WORK/key"
KEY_NAME="$PREFIX-key-$RUN_ID"
hcloud ssh-key create --name "$KEY_NAME" --public-key-from-file "$WORK/key.pub" --label "$RUN_LABEL" >/dev/null
CREATED_KEYS+=("$KEY_NAME")

create_server() { # create_server <name> <type> <image> [extra args...] -> echoes IP (empty if none)
  local name=$1 type=$2 image=$3; shift 3
  hcloud server create --name "$name" --type "$type" --location "$LOCATION" --image "$image" \
    --ssh-key "$KEY_NAME" --user-data-from-file "$WORK/userdata.sh" --label "$RUN_LABEL" "$@" >/dev/null || return 1
  CREATED_SERVERS+=("$name")
  hcloud server describe "$name" -o json | jq -r '.public_net.ipv4.ip // empty'
}
wait_ssh() { # wait_ssh <ip> [jump-ip]
  local ip=$1 jump=${2:-} i out
  for i in $(seq 1 30); do
    if [ -n "$jump" ]; then out=$(ssh_via "$jump" "$ip" hostname 2>/dev/null)
    else out=$(ssh_sut "$ip" hostname 2>/dev/null); fi
    [ -n "$out" ] && return 0; sleep 10
  done; return 1
}

# =========================================================================== basic
SUT_IP=""
scenario_basic() {
  log "scenario basic ($SUT_TYPE from $IMAGE)"
  SUT_IP=$(create_server "$PREFIX-sut-$RUN_ID" "$SUT_TYPE" "$IMAGE") || { check "basic:create" false; return; }
  check "basic:ssh-up" wait_ssh "$SUT_IP"
  check "basic:datasource-hetzner" ssh_sut "$SUT_IP" 'cloud-init status --long | grep -q DataSourceHetzner'
  check "basic:cloud-init-clean" ssh_sut "$SUT_IP" 'cloud-init status --long | grep -qx "extended_status: done"'
  check "basic:userdata-marker" ssh_sut "$SUT_IP" 'test -s /var/lib/gl-boot-test'
  check "basic:dns-trim-3-resolvers" ssh_sut "$SUT_IP" '[ "$(resolvectl dns | sed "s/^[^:]*://" | tr " " "\n" | grep -c .)" -le 3 ] && resolvectl dns | grep -q 185.12.64.1'
  check "basic:inotify" ssh_sut "$SUT_IP" '[ "$(sysctl -n fs.inotify.max_user_instances)" = 8192 ]'
  check "basic:containerd-2.2" ssh_sut "$SUT_IP" 'containerd --version | grep -q " 2\.2\."'
  check "basic:kernel-6.18" ssh_sut "$SUT_IP" 'uname -r | grep -q "^6\."'
  check "basic:os-release-gl" ssh_sut "$SUT_IP" 'grep -q "Garden Linux" /etc/os-release'
  # the data fs grew to the server disk (usi keeps / small; /var is what containerd needs)
  check "basic:datafs-grown" ssh_sut "$SUT_IP" 'r=$(df --output=size -BG / | tail -1 | tr -dc 0-9); v=$(df --output=size -BG /var | tail -1 | tr -dc 0-9); [ "${r:-0}" -ge 60 ] || [ "${v:-0}" -ge 60 ]'
  check "basic:firmware-recorded" ssh_sut "$SUT_IP" 'bootctl status 2>/dev/null | grep -iq firmware || echo BIOS'
  ssh_sut "$SUT_IP" 'bootctl status 2>/dev/null | grep -i "^\s*Firmware:" || echo "  (BIOS boot — no EFI vars)"' | sed 's/^/  /'
}

# =========================================================================== volume
scenario_volume() {
  [ -n "$SUT_IP" ] || { log "skip volume (no SUT)"; return; }
  log "scenario volume"
  local vol="$PREFIX-vol-$RUN_ID"
  hcloud volume create --name "$vol" --size 10 --server "$PREFIX-sut-$RUN_ID" --label "$RUN_LABEL" >/dev/null || { check "volume:create-attach" false; return; }
  CREATED_VOLUMES+=("$vol")
  check "volume:create-attach" true
  local vid; vid=$(hcloud volume describe "$vol" -o json | jq -r .id)
  # udev must surface the by-id symlink on hot-attach; then it must be usable end-to-end
  check "volume:device-appears" ssh_sut "$SUT_IP" "for i in \$(seq 1 12); do [ -e /dev/disk/by-id/scsi-0HC_Volume_$vid ] && exit 0; sleep 5; done; exit 1"
  # mountpoint under /var: on the usi variant / is not writable (immutable-root design)
  check "volume:mkfs-mount-io" ssh_sut "$SUT_IP" "/usr/sbin/mkfs.ext4 -q /dev/disk/by-id/scsi-0HC_Volume_$vid && mkdir -p /var/gl-vol-test && mount /dev/disk/by-id/scsi-0HC_Volume_$vid /var/gl-vol-test && echo io-test > /var/gl-vol-test/f && grep -q io-test /var/gl-vol-test/f && umount /var/gl-vol-test"
  hcloud volume detach "$vol" >/dev/null 2>&1
  check "volume:detach-device-gone" ssh_sut "$SUT_IP" "for i in \$(seq 1 12); do [ ! -e /dev/disk/by-id/scsi-0HC_Volume_$vid ] && exit 0; sleep 5; done; exit 1"
}

# =========================================================================== hot-attach
scenario_hot_attach() {
  [ -n "$SUT_IP" ] || { log "skip hot-attach (no SUT)"; return; }
  log "scenario hot-attach (07-06 netplan-MAC incident class)"
  local net="$PREFIX-net-a-$RUN_ID"
  hcloud network create --name "$net" --ip-range 10.99.0.0/16 --label "$RUN_LABEL" >/dev/null && \
  hcloud network add-subnet "$net" --type cloud --network-zone eu-central --ip-range 10.99.1.0/24 >/dev/null || { check "hot-attach:net-create" false; return; }
  CREATED_NETWORKS+=("$net")
  hcloud server attach-to-network "$PREFIX-sut-$RUN_ID" --network "$net" >/dev/null
  check "hot-attach:nic-ip-no-reboot" ssh_sut "$SUT_IP" 'for i in $(seq 1 12); do ip -4 -brief addr show | grep -q "10\.99\." && exit 0; sleep 5; done; exit 1'
  check "hot-attach:mtu-1450" ssh_sut "$SUT_IP" 'ip link show $(ip -4 -brief addr show | awk "/10\.99\./{print \$1}") | grep -q "mtu 1450"'
  hcloud server detach-from-network "$PREFIX-sut-$RUN_ID" --network "$net" >/dev/null 2>&1
}

# =========================================================================== container
scenario_container() {
  [ -n "$SUT_IP" ] || { log "skip container (no SUT)"; return; }
  log "scenario container (runc/apparmor kill-denial class — /etc/apparmor.d/runc EXISTS on GL)"
  check "container:start" ssh_sut "$SUT_IP" 'systemctl enable --now containerd && ctr version >/dev/null'
  check "container:run" ssh_sut "$SUT_IP" 'ctr image pull registry.k8s.io/pause:3.10 >/dev/null && ctr run -d registry.k8s.io/pause:3.10 glt1'
  # the regression: containerd <1.7.24 + apparmor>=4 could not SIGKILL its containers
  check "container:sigkill-works" ssh_sut "$SUT_IP" 'ctr task kill -s SIGKILL glt1 && for i in $(seq 1 6); do ctr task ls | grep glt1 | grep -q STOPPED && exit 0; sleep 2; done; exit 1'
  ssh_sut "$SUT_IP" 'ctr task rm -f glt1; ctr container rm glt1' >/dev/null 2>&1
}

# =========================================================================== reboot
scenario_reboot() {
  [ -n "$SUT_IP" ] || { log "skip reboot (no SUT)"; return; }
  log "scenario reboot (persistence + no cloud-init re-run)"
  local iid; iid=$(ssh_sut "$SUT_IP" 'cloud-init query instance_id' 2>/dev/null)
  ssh_sut "$SUT_IP" 'systemctl reboot' >/dev/null 2>&1; sleep 15
  check "reboot:ssh-back" wait_ssh "$SUT_IP"
  check "reboot:marker-persists" ssh_sut "$SUT_IP" 'test -s /var/lib/gl-boot-test'
  check "reboot:no-cloudinit-rerun" ssh_sut "$SUT_IP" "[ \"\$(cloud-init query instance_id)\" = '$iid' ] && [ \"\$(grep -c gl-boot-test /var/lib/gl-boot-test)\" = 1 ]"
  check "reboot:dns-persists" ssh_sut "$SUT_IP" 'resolvectl dns enp1s0 | grep -q 185.12.64.1'
  check "reboot:sshd-still-enabled" ssh_sut "$SUT_IP" 'systemctl is-enabled ssh.service'
}

# =========================================================================== private-nat
# Hetzner private DHCP hands out ONLY the IP + gateway/CIDR routes — NO default
# route, NO DNS, NO metadata route (lease dump verified 2026-07-07). Fully-private servers
# (--without-ipv4 --without-ipv6) CANNOT reach 169.254.169.254 at all (probe: timeout via
# private gw too) => no cloud-init user_data => unbootstrappable; that mode is a documented
# platform limit, not a test. The production "0 public IPv4" shape keeps free public IPv6
# + private net for traffic — that is what this scenario builds. v4-less servers still get
# a CGNAT 100.64/10 DHCPv4 lease on the public NIC including an explicit 169.254.169.254
# route (verified 2026-07-07) — metadata + user_data work WITHOUT public IPv4 by design.
# The image must (a) DHCP the private IP, (b) carry static resolvers (our DNS trim),
# (c) accept a persistent networkd route drop-in (the race fix) and reach v4
# internet via the NAT box. Also asserts the GL private-NIC *name* — Ubuntu templates
# match ens10, GL names it enp7s0: the MCM user_data template must cover both.
scenario_private_nat() {
  log "scenario private-nat"
  local net="$PREFIX-net-p-$RUN_ID" natip privname privip
  hcloud network create --name "$net" --ip-range 10.98.0.0/16 --label "$RUN_LABEL" >/dev/null && \
  hcloud network add-subnet "$net" --type cloud --network-zone eu-central --ip-range 10.98.1.0/24 >/dev/null || { check "private-nat:net-create" false; return; }
  CREATED_NETWORKS+=("$net")
  # NAT harness box (stock ubuntu, not the SUT): forward + masquerade
  cat > "$WORK/nat-userdata.sh" <<'EOF'
#!/bin/bash
set -e
sysctl -w net.ipv4.ip_forward=1
echo net.ipv4.ip_forward=1 > /etc/sysctl.d/50-nat.conf
PUB_IF=$(ip -4 route show default | awk '{print $5; exit}')
iptables -t nat -A POSTROUTING -o "$PUB_IF" -s 10.98.0.0/16 -j MASQUERADE
EOF
  hcloud server create --name "$PREFIX-nat-$RUN_ID" --type cpx22 --location "$LOCATION" --image "$NAT_IMAGE" \
    --ssh-key "$KEY_NAME" --user-data-from-file "$WORK/nat-userdata.sh" --network "$net" --label "$RUN_LABEL" >/dev/null || { check "private-nat:nat-create" false; return; }
  CREATED_SERVERS+=("$PREFIX-nat-$RUN_ID")
  natip=$(hcloud server describe "$PREFIX-nat-$RUN_ID" -o json | jq -r .public_net.ipv4.ip)
  natpriv=$(hcloud server describe "$PREFIX-nat-$RUN_ID" -o json | jq -r '.private_net[0].ip')
  # hcloud private nets are NOT L2: peers talk through the fabric router (the .0.1 network
  # gateway) — a default route pointing directly at the NAT box IP dies at ARP. The correct
  # pattern: SUT default via the network gateway + a network-object route 0.0.0.0/0 -> NAT
  # private IP so the fabric hands internet-bound traffic to the NAT box (standard Hetzner
  # NAT-gateway design; the route dies with the network in cleanup)
  hcloud network add-route "$net" --destination 0.0.0.0/0 --gateway "$natpriv" >/dev/null
  # the SUT: no public IPv4 (the Cap A/B "0 IPv4" shape); public IPv6 stays for metadata
  hcloud server create --name "$PREFIX-priv-$RUN_ID" --type "$SUT_TYPE" --location "$LOCATION" --image "$IMAGE" \
    --ssh-key "$KEY_NAME" --user-data-from-file "$WORK/userdata.sh" --network "$net" \
    --without-ipv4 --label "$RUN_LABEL" >/dev/null || { check "private-nat:sut-create" false; return; }
  CREATED_SERVERS+=("$PREFIX-priv-$RUN_ID")
  privip=$(hcloud server describe "$PREFIX-priv-$RUN_ID" -o json | jq -r '.private_net[0].ip')
  check "private-nat:nat-ssh-up" wait_ssh "$natip"
  # ssh-up over the jump proves metadata+user_data worked on an IPv6-only public NIC
  check "private-nat:sut-bootstraps-ipv6-only" wait_ssh "$privip" "$natip"
  check "private-nat:dhcp-private-ip" ssh_via "$natip" "$privip" "ip -4 -brief addr show | grep -q '$privip'"
  privname=$(ssh_via "$natip" "$privip" "ip -4 -brief addr show | awk '/$privip/{print \$1}'" 2>/dev/null)
  log "  private NIC name on GL: ${privname:-unknown} (Ubuntu templates assume ens10)"
  check "private-nat:no-v4-default-route-handed" ssh_via "$natip" "$privip" '! ip -4 route show default | grep -q .'
  check "private-nat:static-dns-baked" ssh_via "$natip" "$privip" "resolvectl dns $privname | grep -q 185.12.64.1"
  # the race fix, GL edition: a dedicated .network file that FULLY owns the private
  # NIC (DHCP + static default route). networkd applies only the FIRST matching .network
  # file per link, so a route-only file would displace 99-default and drop the NIC's DHCP —
  # the exact overwrite-the-IP failure class this scenario exists to catch. Persistent
  # across lease renewals; this is the template for MCM private-pool user_data on GL.
  # the reload reconfigures the very NIC this ssh session rides on — detach it (nohup) and
  # verify from a FRESH connection, else the check kills its own transport and always fails
  # chmod 644 is LOAD-BEARING: GL's hardened root umask writes 640, and networkd runs as
  # the unprivileged systemd-network user — it gets EACCES and silently keeps the old
  # config ("Failed to open ...: Permission denied" in the journal). Any provisioning
  # (MCM user_data included) writing /etc/systemd/network files on GL must chmod 644.
  check "private-nat:route-netfile-staged" ssh_via "$natip" "$privip" "printf '[Match]\nName=$privname\n\n[Network]\nDHCP=yes\n\n[DHCPv4]\nUseMTU=true\n\n[Route]\nDestination=0.0.0.0/0\nGateway=10.98.0.1\nGatewayOnLink=yes\n' > /etc/systemd/network/60-gl-nat.network && chmod 644 /etc/systemd/network/60-gl-nat.network && nohup bash -c 'sleep 1; networkctl reload' >/dev/null 2>&1 & sleep 1; exit 0"
  sleep 12
  check "private-nat:route-netfile-applies" ssh_via "$natip" "$privip" "ip route show default | grep -q via && ip -4 -brief addr show $privname | grep -q '$privip'"
  # v4 literal: a hostname resolves AAAA first and the SUT has no global IPv6 (cloud-init
  # network config is disabled by design), so bash would burn the timeout on the v6 attempt
  check "private-nat:egress-via-nat" ssh_via "$natip" "$privip" 'timeout 15 bash -c "exec 3<>/dev/tcp/185.12.64.1/53"'
  # resolved deprioritizes servers that timed out pre-route — flush + retry until it recovers
  check "private-nat:dns-resolves-via-nat" ssh_via "$natip" "$privip" 'resolvectl flush-caches 2>/dev/null; resolvectl reset-server-features 2>/dev/null; for i in 1 2 3 4 5 6; do getent hosts packages.gardenlinux.io >/dev/null && exit 0; sleep 5; done; exit 1'
}

# =========================================================================== run
log "run $RUN_ID: image=$IMAGE arch=$ARCH type=$SUT_TYPE scenarios=$SCENARIOS"
case ",$SCENARIOS," in *,basic,*) scenario_basic;; esac
case ",$SCENARIOS," in *,volume,*) scenario_volume;; esac
case ",$SCENARIOS," in *,hot-attach,*) scenario_hot_attach;; esac
case ",$SCENARIOS," in *,container,*) scenario_container;; esac
case ",$SCENARIOS," in *,reboot,*) scenario_reboot;; esac
case ",$SCENARIOS," in *,private-nat,*) scenario_private_nat;; esac

echo; echo "==== results (run $RUN_ID, image $IMAGE, $ARCH) ===="
printf '%s\n' "${RESULTS[@]}"
echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" -eq 0 ]
