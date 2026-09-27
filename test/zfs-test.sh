#!/usr/bin/env bash
# zfs-test.sh — does an image built with features/zfs actually carry a usable OpenZFS?
#
# The feature verifies at BUILD time that the module is registered for the right kernel (modinfo).
# That is necessary and not sufficient: modinfo reads a file, it does not load a module, create a
# pool, or survive a reboot. This script does those four things on a real server, because the claim
# the whole ZFS-CSI plan rests on is "a pool on this box comes back", and no build check can say that.
#
#   HCLOUD_TOKEN=... LAB_ZONE=<zone> ./zfs-test.sh --image <snapshot-id> [--type cpx22] [--location nbg1]
#
# Safety: everything it creates carries the gl-zfs- prefix + a per-run label (gl-zfs-run=<id>) and is
# deleted in the EXIT trap. It never touches a resource it did not create, and it refuses to run unless
# the project POSITIVELY proves it is the disposable lab — see the allowlist tripwire below.
set -u -o pipefail

LOCATION=nbg1
TYPE=cpx22
IMAGE=""
KEY="${LAB_SSH_KEY:-$HOME/.ssh/hcloud-gardener_ed25519}"
KEYNAME="${GL_SSH_KEY_NAME:-test-soil}"
RUN_ID="$(date +%s | tail -c 6)$RANDOM"
PREFIX="gl-zfs"
RUN_LABEL="gl-zfs-run=$RUN_ID"
POOL="tank"

while [ $# -gt 0 ]; do case "$1" in
  --image) IMAGE=$2; shift 2;;
  --type) TYPE=$2; shift 2;;
  --location) LOCATION=$2; shift 2;;
  *) echo "unknown argument: $1" >&2; exit 2;;
esac; done

command -v hcloud >/dev/null && command -v jq >/dev/null || { echo "need hcloud + jq" >&2; exit 2; }
[ -n "$IMAGE" ] || { echo "--image <snapshot-id> is required (a raw built with features/zfs)" >&2; exit 2; }
[ -n "${HCLOUD_TOKEN:-}" ] || { echo "HCLOUD_TOKEN is not set" >&2; exit 2; }
[ -r "$KEY" ] || { echo "no ssh key at $KEY (override with LAB_SSH_KEY)" >&2; exit 2; }

# The production tripwire, INVERTED into an allowlist (2026-09-13 security review). The original
# shape blocked one known-bad marker: refuse only when a server named after the operator's
# production convention was visible. That has two problems — (1) it is a blocklist, so any OTHER
# production server, or the same one renamed, sails straight through unrecognised, and (2) to work
# at all it has to spell out the production naming convention in a script this component publishes
# as open source, which hands a reader of the public repo exactly the fact the guard exists to
# protect. It also fails OPEN: if the `hcloud` call above ever errors (bad token, API hiccup), grep
# sees no input, matches nothing, and the script runs anyway.
#
# The allowlist form fails CLOSED instead: it does not run unless the project POSITIVELY proves it
# is the disposable lab, by owning a DNS zone the operator names out-of-band via LAB_ZONE — never a
# literal in this published file. No LAB_ZONE, no ownership match, or an `hcloud` error all refuse
# identically, which is at least as strong as the single string match it replaces.
[ -n "${LAB_ZONE:-}" ] || {
  echo "REFUSING: LAB_ZONE is not set — this script only runs against a project it can positively recognise as the disposable lab (set LAB_ZONE to a DNS zone name this token owns)" >&2; exit 3
}
hcloud zone list -o noheader -o columns=name 2>/dev/null | grep -qx "$LAB_ZONE" || {
  echo "REFUSING: this token does not own zone $LAB_ZONE — not recognised as the disposable lab project" >&2; exit 3
}

SERVER="$PREFIX-$RUN_ID"
VOLUME="$PREFIX-vol-$RUN_ID"
SSH="ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR -i $KEY"
pass=0; fail=0
log(){ printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
row(){ local st="$1"; shift; printf '  [%s] %s\n' "$st" "$*"; [ "$st" = PASS ] && pass=$((pass+1)) || fail=$((fail+1)); }

cleanup(){ rc=$?
  log "cleanup (run $RUN_ID)"
  hcloud volume detach "$VOLUME" >/dev/null 2>&1
  hcloud volume delete "$VOLUME" >/dev/null 2>&1
  hcloud server delete "$SERVER" >/dev/null 2>&1
  log "== $pass PASS / $fail FAIL =="
  [ "$fail" = 0 ] || rc=1
  exit $rc; }
trap cleanup EXIT INT TERM

log "creating $SERVER ($TYPE, $LOCATION) from image $IMAGE"
hcloud server create --name "$SERVER" --type "$TYPE" --location "$LOCATION" --image "$IMAGE" \
  --ssh-key "$KEYNAME" --label "$RUN_LABEL" >/dev/null || { echo "server create failed" >&2; exit 1; }
IP="$(hcloud server ip "$SERVER")"
up=""; for _ in $(seq 1 60); do $SSH "root@$IP" true 2>/dev/null && { up=1; break; }; sleep 5; done
[ -n "$up" ] || { echo "no ssh to $IP" >&2; exit 1; }

# A separate volume, not the root disk: that is how a node gets its data area, and it keeps the test
# from depending on how much slack the root filesystem happens to have.
log "attaching a 10G volume"
hcloud volume create --name "$VOLUME" --size 10 --location "$LOCATION" --label "$RUN_LABEL" --format "" >/dev/null \
  || { echo "volume create failed" >&2; exit 1; }
hcloud volume attach "$VOLUME" --server "$SERVER" --automount=false >/dev/null || { echo "attach failed" >&2; exit 1; }
DEV="/dev/disk/by-id/scsi-0HC_Volume_$(hcloud volume describe "$VOLUME" -o format='{{.ID}}')"
sleep 5

# ── 1. the module loads ──────────────────────────────────────────────────────────────────────────
# The build check used modinfo, which only reads a file. This is the first moment anything proves
# the module matches the running kernel.
if $SSH "root@$IP" 'modprobe zfs && lsmod | grep -q "^zfs"' 2>/dev/null; then
  row PASS "das zfs-Modul lädt auf dem laufenden Kernel ($($SSH "root@$IP" 'uname -r' 2>/dev/null))"
else
  row FAIL "modprobe zfs schlug fehl — das Modul passt nicht zum laufenden Kernel"
  $SSH "root@$IP" 'uname -r; modprobe zfs 2>&1 | head -3; dkms status 2>/dev/null | head -3' 2>&1 | sed 's/^/      /'
  exit 1
fi

# ── 2. ein Pool auf dem Datenträger ──────────────────────────────────────────────────────────────
if $SSH "root@$IP" "zpool create -f $POOL $DEV && zpool list -H -o name | grep -qx $POOL" 2>/dev/null; then
  row PASS "zpool create auf einem angehängten Volume ($(basename "$DEV"))"
else
  row FAIL "zpool create schlug fehl"
fi

# ── 3. Dataset, Snapshot, Clone — der Kapazitätsmultiplikator ────────────────────────────────────
# Das ist die Behauptung, auf der die Kapazitätsrechnung für Educates beruht: ein vorbereitetes
# Dataset, per copy-on-write je Teilnehmer geklont, statt N vollen Kopien. Hier wird sie gemessen,
# nicht angenommen: 64 MiB Nutzdaten, danach muss der Klon fast nichts zusätzlich belegen.
if $SSH "root@$IP" "
    zfs create $POOL/workshop &&
    dd if=/dev/urandom of=/$POOL/workshop/payload bs=1M count=64 status=none &&
    sync && zfs snapshot $POOL/workshop@prepared &&
    zfs clone $POOL/workshop@prepared $POOL/session-1 &&
    zfs clone $POOL/workshop@prepared $POOL/session-2 &&
    test -s /$POOL/session-1/payload && test -s /$POOL/session-2/payload" 2>/dev/null; then
  used="$($SSH "root@$IP" "zfs list -Hp -o used $POOL/session-1" 2>/dev/null)"
  row PASS "Snapshot + zwei Klone; ein Klon von 64 MiB Nutzdaten belegt ${used:-?} Bytes (copy-on-write)"
  [ -n "$used" ] && [ "$used" -lt 10000000 ] \
    && row PASS "der Klon ist wirklich fast gratis (< 10 MB) — die Kapazitätsrechnung trägt" \
    || row FAIL "der Klon belegt ${used:-?} Bytes — mehr als copy-on-write erwarten lässt"
else
  row FAIL "Dataset/Snapshot/Clone schlug fehl"
fi

# ── 4. und nach einem Neustart? ──────────────────────────────────────────────────────────────────
# Der Punkt, an dem sich entscheidet, ob das Feature etwas wert ist. Ein Pool, der nach einem Reboot
# von Hand importiert werden muss, ist für einen Knoten nutzlos: niemand loggt sich dort ein.
log "rebooting to see whether the pool comes back on its own"
$SSH "root@$IP" 'systemctl reboot' >/dev/null 2>&1 || true
sleep 20
up=""; for _ in $(seq 1 60); do $SSH "root@$IP" true 2>/dev/null && { up=1; break; }; sleep 5; done
if [ -z "$up" ]; then
  row FAIL "die Box kam nach dem Neustart nicht zurück"
else
  if $SSH "root@$IP" "zpool list -H -o name | grep -qx $POOL" 2>/dev/null; then
    row PASS "der Pool ist nach dem Neustart von selbst importiert (zfs-import-cache + zfs.target)"
  else
    row FAIL "der Pool war nach dem Neustart nicht importiert — die Units greifen nicht"
    $SSH "root@$IP" 'systemctl is-enabled zfs-import-cache.service zfs-mount.service zfs.target 2>&1 | tr "\n" " "' 2>&1 | sed 's/^/      /'
  fi
  $SSH "root@$IP" "test -s /$POOL/session-1/payload" 2>/dev/null \
    && row PASS "der Klon ist nach dem Neustart noch da und gemountet" \
    || row FAIL "der Klon fehlte nach dem Neustart"
fi

# Aufräumen auf der Box selbst ist nicht nötig — Volume und Server gehen im Trap. Den Pool trotzdem
# exportieren, damit ein Volume, das jemand behält, nicht als 'in use by another system' gilt.
$SSH "root@$IP" "zpool export $POOL" >/dev/null 2>&1 || true
