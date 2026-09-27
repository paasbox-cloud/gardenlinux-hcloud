#!/usr/bin/env bash
# Robot (dedicated bare-metal) re-image + boot test for the GL metal flavor — the dedicated
# analogue of rebuild-pet-test.sh. Deploy path = the only one Robot has:
# rescue-boot + stream the raw image to disk (installimage has no custom-image support).
#
#   ROBOT_USER=... ROBOT_PASSWORD=... ./rebuild-robot-test.sh \
#       --server <number> --ip <ipv4> --image <raw.zst path> --key <ssh-private-key> --wipe \
#       [--disk nvme0n1] [--vswitch <id> --vlan <id> --vlan-ip <cidr> --peer <ip>]
#
# DESTRUCTIVE: dd-wipes the target disk — hence the mandatory --wipe acknowledgement AND a
# hard guard: if the box answers ssh with a shoot--* hostname (a live Gardener node), ABORT.
# Recovery from a non-booting image: Robot API rescue + hw reset (exactly what this script
# uses to get in). The --key must be Robot-registered (GET /key) for rescue activation.
set -u -o pipefail

SERVER="" IP="" IMAGE="" KEY="" DISK=nvme0n1 WIPE=no VSWITCH="" VLAN="" VLANIP="" PEER=""
while [ $# -gt 0 ]; do case "$1" in
  --server) SERVER=$2; shift 2;;
  --ip) IP=$2; shift 2;;
  --image) IMAGE=$2; shift 2;;
  --key) KEY=$2; shift 2;;
  --disk) DISK=$2; shift 2;;
  --wipe) WIPE=yes; shift;;
  --vswitch) VSWITCH=$2; shift 2;;
  --vlan) VLAN=$2; shift 2;;
  --vlan-ip) VLANIP=$2; shift 2;;
  --peer) PEER=$2; shift 2;;
  *) echo "unknown arg $1"; exit 2;;
esac; done
[ -n "$SERVER" ] && [ -n "$IP" ] && [ -f "${IMAGE:-/nonexistent}" ] && [ -f "${KEY:-/nonexistent}" ] || {
  echo "--server, --ip, --image <file>, --key <file> required"; exit 2; }
[ "$WIPE" = yes ] || { echo "refusing without --wipe (this dd-wipes /dev/$DISK on server $SERVER)"; exit 2; }
[ -n "${ROBOT_USER:-}" ] && [ -n "${ROBOT_PASSWORD:-}" ] || { echo "ROBOT_USER/ROBOT_PASSWORD required"; exit 2; }

RAPI="https://robot-ws.your-server.de"
PASS=0; FAIL=0; RESULTS=()
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); RESULTS+=("PASS $n"); log "  PASS $n"; else FAIL=$((FAIL+1)); RESULTS+=("FAIL $n"); log "  FAIL $n"; fi; }
SSHO=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes -i "$KEY")
S() { ssh "${SSHO[@]}" "root@$IP" "$@"; }
wait_host() { # wait_host <want:rescue|disk>
  local want=$1 i h
  for i in $(seq 1 36); do h=$(S hostname 2>/dev/null)
    case "$want" in
      rescue) [ "$h" = "rescue" ] && return 0;;
      disk)   [ -n "$h" ] && [ "$h" != "rescue" ] && return 0;;
    esac; sleep 10
  done; return 1
}

# 0. safety guard — never wipe a live Gardener node
H=$(S hostname 2>/dev/null || true)
case "$H" in shoot--*) echo "ABORT: $IP answers as '$H' — a live Gardener node"; exit 3;; esac
log "target: server $SERVER ($IP, disk $DISK, current host: ${H:-unreachable})"

# 1. rescue via Robot API (key fingerprint must be Robot-registered) + hardware reset
FP=$(ssh-keygen -l -E md5 -f "$KEY" 2>/dev/null | awk '{print $2}' | sed 's/^MD5://')
[ -n "$FP" ] || { echo "cannot derive fingerprint from $KEY"; exit 2; }
curl -sf -u "$ROBOT_USER:$ROBOT_PASSWORD" -X POST "$RAPI/boot/$SERVER/rescue" \
  -d "os=linux" -d "authorized_key[]=$FP" >/dev/null || { echo "rescue activation failed (key registered in Robot?)"; exit 1; }
curl -sf -u "$ROBOT_USER:$ROBOT_PASSWORD" -X POST "$RAPI/reset/$SERVER" -d "type=hw" >/dev/null || { echo "hw reset failed"; exit 1; }
check "rescue:activated+reset" true
log "waiting for rescue"
wait_host rescue || { echo "rescue unreachable"; exit 1; }
check "rescue:ssh-up" true

# 2. wipe + stream image (zero other disks' signatures so no stale bootloader wins BIOS order)
S "for d in \$(lsblk -dno NAME | grep -v -e '^$DISK\$' -e loop); do wipefs -a /dev/\$d >/dev/null 2>&1; done; blkdiscard -f /dev/$DISK" || { echo "disk prep failed"; exit 1; }
case "$IMAGE" in # local builds ship .zst, CI release assets .xz
  *.zst) DC="zstd -dc";; *.xz) DC="xz -dc";; *.raw) DC="cat";;
  *) echo "unknown image compression: $IMAGE"; exit 2;;
esac
log "streaming $(du -h "$IMAGE" | cut -f1) image to /dev/$DISK ($DC)"
cat "$IMAGE" | S "$DC | dd of=/dev/$DISK bs=4M conv=fsync status=none && sync" || { echo "dd failed"; exit 1; }
check "deploy:dd" true

# 3. inject ssh enablement + this key (image has no cloud-init/metadata)
ssh-keygen -y -f "$KEY" | S '
set -e
blockdev --rereadpt /dev/'"$DISK"' 2>/dev/null; sleep 2
ROOTDEV=$(blkid -L ROOT); mkdir -p /mnt; mount "$ROOTDEV" /mnt
mkdir -p /mnt/etc/systemd/system/multi-user.target.wants /mnt/etc/ssh/authorized_keys.d /mnt/root/.ssh
ln -sf /usr/lib/systemd/system/ssh.service /mnt/etc/systemd/system/multi-user.target.wants/ssh.service
cat /dev/stdin > /mnt/etc/ssh/authorized_keys.d/root
cp /mnt/etc/ssh/authorized_keys.d/root /mnt/root/.ssh/authorized_keys
grep -q "^Include /etc/ssh/sshd_config.d" /mnt/etc/ssh/sshd_config || sed -i "1i Include /etc/ssh/sshd_config.d/*.conf" /mnt/etc/ssh/sshd_config
printf "AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys.d/%%u\n" > /mnt/etc/ssh/sshd_config.d/70-gl-robot-test.conf
umount /mnt' || { echo "injection failed"; exit 1; }
check "deploy:ssh-injected" true
S reboot >/dev/null 2>&1; sleep 15

# 4. boot checks
log "waiting for GL metal boot"
check "boot:ssh-up" wait_host disk
check "boot:garden-linux" S 'grep -q "Garden Linux" /etc/os-release'
check "boot:full-kernel-not-cloud" S 'uname -r | grep -qv cloud'
check "boot:dhcp-primary-ip" S "ip -4 -brief addr show | grep -q $IP"
check "boot:dns-trim" S 'resolvectl status | grep -q 185.12.64.1'
check "boot:containerd-2.2" S 'containerd --version | grep -q " 2\.2\."'
check "boot:8021q-loadable" S 'modprobe -n 8021q'
log "  kernel: $(S uname -r 2>/dev/null) · firmware: $(S 'bootctl status 2>/dev/null | grep -i "^\s*Firmware:" || echo BIOS' 2>/dev/null)"

# 5. optional vSwitch/VLAN validation (ping a PEER, never the gateway — it drops ICMP)
if [ -n "$VSWITCH" ] && [ -n "$VLAN" ] && [ -n "$VLANIP" ] && [ -n "$PEER" ]; then
  curl -sf -u "$ROBOT_USER:$ROBOT_PASSWORD" -X POST "$RAPI/vswitch/$VSWITCH/server" -d "server[]=$SERVER" >/dev/null
  for i in $(seq 1 18); do
    st=$(curl -s -u "$ROBOT_USER:$ROBOT_PASSWORD" "$RAPI/vswitch/$VSWITCH" | jq -r ".server[] | select(.server_number==$SERVER) | .status")
    [ "$st" = "ready" ] && break; sleep 10
  done
  check "vswitch:attached-ready" [ "$st" = "ready" ]
  NIC=$(S "ip -4 -brief addr show | awk '/$IP/{print \$1}'" 2>/dev/null)
  check "vswitch:vlan-peer-ping" S "modprobe 8021q && ip link add link $NIC name vlan$VLAN type vlan id $VLAN && ip link set vlan$VLAN mtu 1400 up && ip addr add $VLANIP dev vlan$VLAN && sleep 2 && ping -c 3 -W 3 $PEER"
  S "ip link del vlan$VLAN" >/dev/null 2>&1
  curl -sf -u "$ROBOT_USER:$ROBOT_PASSWORD" -X DELETE "$RAPI/vswitch/$VSWITCH/server" -d "server[]=$SERVER" >/dev/null
  check "vswitch:detached" true
fi

echo; echo "==== robot-rebuild results (server $SERVER, $IP, image $(basename "$IMAGE")) ===="
printf '%s\n' "${RESULTS[@]}"
echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" -eq 0 ]
