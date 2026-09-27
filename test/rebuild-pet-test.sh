#!/usr/bin/env bash
# Grandfathered-pet rebuild test: validates the price-safe family-swap path
# (Gardener "roll" = hcloud `rebuild`, same server ID/type/price) with a GL snapshot —
# and doubles as the BIOS (CX*) / arm64 (CAX*) firmware coverage the throwaway suite
# (run-tests.sh) cannot provide, since those families aren't (all) orderable new.
#
#   HCLOUD_TOKEN=... ./rebuild-pet-test.sh --server <id> --image <snapshot-id> [--power-off-after]
#
# PRICE-SAFETY CONTRACT: this script NEVER calls `server delete` or
# `change_type` — the only two repricing events. It temporarily lifts REBUILD protection
# only, keeps DELETE protection untouched, and re-asserts both at the end.
#
# Rebuild keeps the server's ORIGINAL create-time user_data (the API has no user_data on
# rebuild — same reason nodepool-core's claim-rebuild path exists), so sshd stays disabled
# by the gardener_prod preset. We enable it via one rescue round: wants-symlink for
# ssh.service + an authorized_keys.d drop-in (works on classic AND usi, whose /root is tmpfs).
set -u -o pipefail

SERVER="" IMAGE="" POWEROFF=no
while [ $# -gt 0 ]; do case "$1" in
  --server) SERVER=$2; shift 2;;
  --image) IMAGE=$2; shift 2;;
  --power-off-after) POWEROFF=yes; shift;;
  *) echo "unknown arg $1"; exit 2;;
esac; done
[ -n "$SERVER" ] && [ -n "$IMAGE" ] || { echo "--server <id> --image <snapshot-id> required"; exit 2; }
[ -n "${HCLOUD_TOKEN:-}" ] || { echo "HCLOUD_TOKEN required"; exit 2; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0; RESULTS=()
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); RESULTS+=("PASS $n"); log "  PASS $n"; else FAIL=$((FAIL+1)); RESULTS+=("FAIL $n"); log "  FAIL $n"; fi; }

J=$(hcloud server describe "$SERVER" -o json)
NAME=$(jq -r .name <<<"$J"); TYPE=$(jq -r .server_type.name <<<"$J")
IP=$(jq -r '.public_net.ipv4.ip // empty' <<<"$J")
PROT_DELETE=$(jq -r .protection.delete <<<"$J"); PROT_REBUILD=$(jq -r .protection.rebuild <<<"$J")
[ -n "$IP" ] || { echo "server has no public IPv4 — this test needs one"; exit 2; }
log "pet: $NAME ($SERVER, $TYPE, ip $IP, protection delete=$PROT_DELETE rebuild=$PROT_REBUILD)"

SSHO=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes -i "$WORK/key")
ssh-keygen -q -t ed25519 -N '' -f "$WORK/key"
KEY_NAME="gl-test-pet-$SERVER"
hcloud ssh-key create --name "$KEY_NAME" --public-key-from-file "$WORK/key.pub" >/dev/null
wait_ssh() { for i in $(seq 1 30); do out=$(ssh "${SSHO[@]}" "root@$IP" hostname 2>/dev/null); [ -n "$out" ] && { echo "$out"; return 0; }; sleep 10; done; return 1; }

finish() {
  # re-assert protection no matter what (the ManagedServer contract), drop the temp key
  hcloud server enable-protection "$SERVER" rebuild delete >/dev/null 2>&1
  hcloud ssh-key delete "$KEY_NAME" >/dev/null 2>&1
}
trap 'finish; rm -rf "$WORK"' EXIT

# 1. rebuild (price-safe; lifts rebuild protection only)
[ "$PROT_REBUILD" = "true" ] && hcloud server disable-protection "$SERVER" rebuild >/dev/null
log "rebuilding $NAME from image $IMAGE (same server id — the Layer-2 swap)"
hcloud server rebuild "$SERVER" --image "$IMAGE" >/dev/null || { echo "rebuild failed"; exit 1; }
check "rebuild:accepted" true

# 2. one rescue round to enable sshd + inject our key (survives on classic and usi)
hcloud server enable-rescue "$SERVER" --ssh-key "$KEY_NAME" >/dev/null
hcloud server reboot "$SERVER" >/dev/null
log "waiting for rescue"
H=$(wait_ssh) || { echo "rescue unreachable"; exit 1; }
[ "${H}" = "rescue" ] || log "  (warn: expected rescue, got $H)"
ssh "${SSHO[@]}" "root@$IP" '
set -e
ROOTDEV=$(blkid -L ROOT); mkdir -p /mnt; mount "$ROOTDEV" /mnt
mkdir -p /mnt/etc/systemd/system/multi-user.target.wants
ln -sf /usr/lib/systemd/system/ssh.service /mnt/etc/systemd/system/multi-user.target.wants/ssh.service
mkdir -p /mnt/etc/ssh/authorized_keys.d /mnt/root/.ssh
printf "AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys.d/%%u\nPermitRootLogin prohibit-password\n" > /mnt/etc/ssh/sshd_config.d/70-gl-pet-test.conf
cat > /mnt/etc/ssh/authorized_keys.d/root < /dev/stdin
cp /mnt/etc/ssh/authorized_keys.d/root /mnt/root/.ssh/authorized_keys 2>/dev/null || true
umount /mnt' < "$WORK/key.pub" || { echo "rescue injection failed"; exit 1; }
check "rescue:ssh-enabled+key-injected" true
ssh "${SSHO[@]}" "root@$IP" reboot >/dev/null 2>&1; sleep 15

# 3. boot + checks on the rebuilt pet
log "waiting for GL boot"
check "boot:ssh-up" wait_ssh
S() { ssh "${SSHO[@]}" "root@$IP" "$@"; }
check "boot:garden-linux" S 'grep -q "Garden Linux" /etc/os-release'
ARCH_OUT=$(S 'uname -m' 2>/dev/null); FW_OUT=$(S 'bootctl status 2>/dev/null | grep -i "^\s*Firmware:" || echo "BIOS (no EFI)"' 2>/dev/null)
log "  arch: $ARCH_OUT · firmware: $FW_OUT · kernel: $(S uname -r 2>/dev/null)"
check "boot:datasource-hetzner" S 'cloud-init status --long | grep -q DataSourceHetzner'
check "boot:dns-trim" S 'resolvectl status | grep -q 185.12.64.1'
check "boot:containerd-2.2" S 'containerd --version | grep -q " 2\.2\."'
check "boot:rootfs-grown-to-disk" S '[ "$(df --output=size -BG / | tail -1 | tr -dc 0-9)" -ge 100 ]'
# price-safety evidence: same server id + type after the whole cycle
J2=$(hcloud server describe "$SERVER" -o json)
check "price:server-id-unchanged" [ "$(jq -r .id <<<"$J2")" = "$SERVER" ]
check "price:type-unchanged" [ "$(jq -r .server_type.name <<<"$J2")" = "$TYPE" ]

# 4. re-assert protection (also in trap), optional power-off
finish
check "protection:reasserted" bash -c "hcloud server describe $SERVER -o json | jq -e '.protection.delete and .protection.rebuild'"
[ "$POWEROFF" = yes ] && { hcloud server poweroff "$SERVER" >/dev/null 2>&1; log "powered off"; }

echo; echo "==== pet-rebuild results ($NAME/$SERVER, $TYPE, image $IMAGE) ===="
printf '%s\n' "${RESULTS[@]}"
echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" -eq 0 ]
