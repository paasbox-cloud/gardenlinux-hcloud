#!/usr/bin/env bash
# k3s-update-test.sh — checks 4 and 5 of features/k3s/README.md ("Testing"), automated: an IN-PLACE
# image update of ONE booted `_usi` k3s server node, and the rollback, while node-local volumes
# (LocalPV-LVM in vg0) carry state. Same SSH conventions as test/k3s-node-test.sh: root over SSH to
# the node, every step a remote snippet. Where the node runs does not matter (a vz VM on a Mac, KVM,
# an hcloud server); it must have passed k3s-node-test.sh's checks image and 1.
#
#   test/k3s-update-test.sh --host <ip> [--port 22] [--key <file>] --new-uki <local .uki>
#       [--new-entry <name>.efi] [--expect-new <k3s version>] [--same-version]
#       [--no-drain] [--no-rollback] [--timeout 900]
#
#   before    workload state on local-lvm-thin, pinned to this node: (a) a PVC holding a 32 MiB
#             random file of known sha256; (b) a Postgres StatefulSet (postgres:17-alpine) whose PVC
#             holds a table of 10000 rows; a Secret with a random value. Recorded: the node's k3s
#             version, its name and UID, every LV in vg0 by name AND UUID, the LVMVolume objects, the
#             PVC→PV bindings with both UIDs.
#   update    k3s etcd-snapshot save (required before a k3s MINOR change — the A/B slot cannot undo a
#             datastore migration; refused if the minor changes on a node without etcd), cordon +
#             drain, the new UKI onto the ESP under --new-entry, `bootctl set-default`, reboot,
#             wait for Ready, uncordon, wait for the pods.
#   verify    k3s reports the new version (or the SAME one with --same-version, which is then not an
#             upgrade and is labelled so); systemd-boot booted the new entry; the same LVs (same
#             UUIDs: not recreated) and LVMVolumes; the PVCs Bound to the same PVs (same UIDs); the
#             node object the same (UID); the pods back on this node; sha256, rows and Secret intact.
#   rollback  (README §5, only within one k3s minor) writes more state under the new version,
#             `bootctl set-default` back to the entry that was booted before, reboot, and verifies
#             the same again — with the old version and the rows written under the new one.
#
# The update step is what `gardenlinux-update` does AFTER it has pulled and verified an artifact:
# write the UKI to /efi/EFI/Linux and make it the default. Its OCI half is not exercised here — the
# repository it pulls from (/etc/gardenlinux/usirepo.conf) has no published update images yet.
#
# Phases are timed (drain, reboot → ssh, → node Ready on the new boot, uncordon → pods Ready); the
# table is printed at the end. Exit status: 0 when every check passed. Leaves namespace
# k3s-update-test and the second UKI on the ESP behind (delete, or throw the node away).
# shellcheck disable=SC2319 # "$([ … ]; echo $?)" hands local_check the condition's status, on purpose
set -u -o pipefail

HOST="" PORT=22 KEY="" NEW_UKI="" NEW_ENTRY="" EXPECT_NEW="" SAME=0 DRAIN=1 ROLLBACK=1 TIMEOUT=900
while [ $# -gt 0 ]; do case "$1" in
	--host) HOST=$2; shift 2 ;;
	--port) PORT=$2; shift 2 ;;
	--key) KEY=$2; shift 2 ;;
	--new-uki) NEW_UKI=$2; shift 2 ;;
	--new-entry) NEW_ENTRY=$2; shift 2 ;;
	--expect-new) EXPECT_NEW=$2; shift 2 ;;
	--same-version) SAME=1; shift ;;
	--no-drain) DRAIN=0; shift ;;
	--no-rollback) ROLLBACK=0; shift ;;
	--timeout) TIMEOUT=$2; shift 2 ;;
	*) echo "unknown arg $1" >&2; exit 2 ;;
esac; done
[ -n "$HOST" ] || { echo "--host required" >&2; exit 2; }
[ -f "$NEW_UKI" ] || { echo "--new-uki <file> required" >&2; exit 2; }

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR)
[ -n "$KEY" ] && SSH_OPTS+=(-i "$KEY")
NS=k3s-update-test
PASS=0 FAIL=0 RESULTS=() TIMES=()

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
node() { ssh "${SSH_OPTS[@]}" -p "$PORT" "root@$HOST" "$@"; }
check() {
	local name=$1 out rc
	out="$(node "$2" 2>&1)"; rc=$?
	[ -n "$out" ] && sed 's/^/      /' <<< "$out"
	if [ $rc -eq 0 ]; then PASS=$((PASS + 1)); RESULTS+=("PASS $name"); log "  PASS $name"
	else FAIL=$((FAIL + 1)); RESULTS+=("FAIL $name"); log "  FAIL $name"; fi
	return $rc
}
# local_check <name> <exit status> [detail] — a check whose comparison runs here, not on the node
local_check() {
	if [ "$2" -eq 0 ]; then PASS=$((PASS + 1)); RESULTS+=("PASS $1"); log "  PASS $1"
	else FAIL=$((FAIL + 1)); RESULTS+=("FAIL $1"); log "  FAIL $1${3:+ — $3}"; fi
}
WAITED=0
wait_for() {
	local what=$1 snippet=$2 limit=${3:-$TIMEOUT} start=$SECONDS
	log "  waiting for $what (≤${limit}s)"
	until node "$snippet" > /dev/null 2>&1; do
		[ $((SECONDS - start)) -ge "$limit" ] && { WAITED=$((SECONDS - start)); log "  timed out waiting for $what"; return 1; }
		sleep 2
	done
	WAITED=$((SECONDS - start))
	log "  $what after ${WAITED}s"
}
timed() { TIMES+=("$(printf '%-9s %-44s %5ss' "$1" "$2" "$3")"); }
minor() { cut -d. -f2 <<< "$1"; }

wait_for "ssh" true 600 || exit 1
NODE="$(node hostname)"
OLD_VER="$(node 'k3s --version | head -1' | awk '{print $3}')"
OLD_ENTRY="$(node 'bootctl status 2>/dev/null' | awk -F': ' '/Current Entry:/ {print $2}' | xargs)"
[ -n "$NEW_ENTRY" ] || NEW_ENTRY="${OLD_ENTRY%.efi}-update.efi"
[ "$NEW_ENTRY" != "$OLD_ENTRY" ] || { echo "--new-entry must differ from the booted entry $OLD_ENTRY" >&2; exit 2; }
log "node $NODE: k3s $OLD_VER, booted entry $OLD_ENTRY; the update writes $NEW_ENTRY"

openebs_ready='kubectl -n openebs get pods --no-headers | grep -v Completed | awk "{ split(\$2, r, \"/\"); n++; if (r[1] != r[2] || \$3 != \"Running\") bad=1 } END { exit bad || n < 2 }"'
wait_for "node Ready and LocalPV-LVM ready" "kubectl get node $NODE --no-headers | grep -qw Ready && $openebs_ready" || exit 1
# a previous run's state would be read as this run's baseline (10500 rows, another file) — start clean
node "! kubectl get namespace $NS >/dev/null 2>&1" || { echo "namespace $NS exists from an earlier run: kubectl delete namespace $NS --wait, then rerun" >&2; exit 2; }

# ---------------------------------------------------------------------------------------------------
log "before — workload state on local-lvm-thin, pinned to $NODE"
node "kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n $NS create secret generic pg-auth --from-literal=POSTGRES_PASSWORD=\$(head -c 12 /dev/urandom | base64 | tr -dc a-zA-Z0-9) --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n $NS create secret generic marker --from-literal=value=\$(head -c 24 /dev/urandom | base64 | tr -dc a-zA-Z0-9) --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: blob, namespace: $NS}
spec:
  storageClassName: local-lvm-thin
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: blob, namespace: $NS}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: blob}}
  template:
    metadata: {labels: {app: blob}}
    spec:
      nodeSelector: {kubernetes.io/hostname: $NODE}
      terminationGracePeriodSeconds: 1
      containers:
        - name: c
          image: busybox:1.37
          command: [sh, -c, 'sleep 2147483647']
          volumeMounts: [{name: d, mountPath: /data}]
      volumes: [{name: d, persistentVolumeClaim: {claimName: blob}}]
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: pg, namespace: $NS}
spec:
  replicas: 1
  serviceName: pg
  selector: {matchLabels: {app: pg}}
  template:
    metadata: {labels: {app: pg}}
    spec:
      nodeSelector: {kubernetes.io/hostname: $NODE}
      containers:
        - name: postgres
          image: postgres:17-alpine
          envFrom: [{secretRef: {name: pg-auth}}]
          env: [{name: PGDATA, value: /var/lib/postgresql/data/pgdata}]
          readinessProbe: {exec: {command: [pg_isready, -U, postgres]}, periodSeconds: 2}
          volumeMounts: [{name: data, mountPath: /var/lib/postgresql/data}]
  volumeClaimTemplates:
    - metadata: {name: data}
      spec:
        storageClassName: local-lvm-thin
        accessModes: [ReadWriteOnce]
        resources: {requests: {storage: 1Gi}}
EOF"
wait_for "blob pod and Postgres ready" "kubectl -n $NS rollout status deploy/blob --timeout=5s && kubectl -n $NS rollout status sts/pg --timeout=5s && kubectl -n $NS exec pg-0 -- pg_isready -U postgres" || true
psql() { node "kubectl -n $NS exec pg-0 -- psql -U postgres -v ON_ERROR_STOP=1 -tAc \"$1\""; }
# rows: count and a digest over every row, so a lost or changed row shows, not only a lost table
ROWS_Q="select count(*) || ' ' || md5(string_agg(id || ':' || v, ',' order by id)) from t"
node "kubectl -n $NS exec deploy/blob -- sh -c 'head -c 33554432 /dev/urandom > /data/blob && sync'"
BLOB_SHA="$(node "kubectl -n $NS exec deploy/blob -- sha256sum /data/blob" | awk '{print $1}')"
psql "create table if not exists t (id int primary key, v text); insert into t select i, md5(i::text) from generate_series(1, 10000) i on conflict do nothing" > /dev/null
ROWS="$(psql "$ROWS_Q")"
SECRET="$(node "kubectl -n $NS get secret marker -o jsonpath='{.data.value}' | base64 -d")"
log "  blob sha256 $BLOB_SHA; Postgres rows $ROWS; Secret ${SECRET:0:6}…"
local_check "the workload state was created (blob, 10000 rows, Secret)" "$([ ${#BLOB_SHA} -eq 64 ] && [ "${ROWS%% *}" = 10000 ] && [ -n "$SECRET" ]; echo $?)"

# identity: what must NOT change when the node updates in place. LV sizes are left out — the thin
# pool may autoextend — but names and UUIDs are what a recreated volume could never keep.
state() {
	node "set -e
	echo \"node $NODE \$(kubectl get node $NODE -o jsonpath='{.metadata.uid}')\"
	lvs --noheadings -o lv_name,lv_uuid,segtype vg0 | awk '{print \"lv\", \$1, \$2, \$3}' | sort
	kubectl -n openebs get lvmvolume -o jsonpath='{range .items[*]}lvmvolume {.metadata.name} {.metadata.uid} {.spec.ownerNodeID}{\"\\n\"}{end}' | sort
	for c in \$(kubectl -n $NS get pvc -o name); do
		kubectl -n $NS get \$c -o jsonpath='pvc {.metadata.name} {.metadata.uid} {.status.phase} {.spec.volumeName} '
		kubectl get pv \$(kubectl -n $NS get \$c -o jsonpath='{.spec.volumeName}') -o jsonpath='{.metadata.uid} {.status.phase}{\"\\n\"}'
	done | sort"
}
BEFORE="$(state)"
sed 's/^/      /' <<< "$BEFORE"
local_check "identity recorded (node, ≥2 LVs besides the thin pool, 2 Bound PVCs)" \
	"$([ "$(grep -c '^lv .* thin$' <<< "$BEFORE")" -ge 2 ] && [ "$(grep -c '^pvc .* Bound .* Bound$' <<< "$BEFORE")" -eq 2 ]; echo $?)"

# verify <label> <expected k3s version> <expected entry> <expected rows>
verify() {
	local label=$1 ver=$2 entry=$3 rows=$4 now
	log "verify — $label"
	check "[$label] k3s is $ver (binary and kubelet)" "
		k3s --version | head -1
		[ \"\$(k3s --version | head -1 | awk '{print \$3}')\" = '$ver' ] &&
		[ \"\$(kubectl get node $NODE -o jsonpath='{.status.nodeInfo.kubeletVersion}')\" = '$ver' ]"
	check "[$label] systemd-boot booted $entry" "bootctl status 2>/dev/null | grep -F 'Current Entry: $entry'"
	now="$(state)"
	local d; d="$(diff <(echo "$BEFORE") <(echo "$now"))"
	[ -n "$d" ] && sed 's/^/      /' <<< "$d"
	local_check "[$label] same node object, same LVs (name+UUID), same LVMVolumes, PVCs Bound to the same PVs" "$([ -z "$d" ]; echo $?)"
	check "[$label] the pods are back on $NODE" "
		kubectl -n $NS get pods -o wide --no-headers
		[ -z \"\$(kubectl -n $NS get pods -o jsonpath='{range .items[*]}{.spec.nodeName}{\"\\n\"}{end}' | grep -vx '$NODE')\" ]"
	now="$(node "kubectl -n $NS exec deploy/blob -- sha256sum /data/blob" | awk '{print $1}')"
	local_check "[$label] the file's sha256 is intact" "$([ "$now" = "$BLOB_SHA" ]; echo $?)" "$now"
	now="$(psql "$ROWS_Q")"
	local_check "[$label] the Postgres rows are intact ($rows)" "$([ "$now" = "$rows" ]; echo $?)" "$now"
	now="$(node "kubectl -n $NS get secret marker -o jsonpath='{.data.value}' | base64 -d")"
	local_check "[$label] the Secret reads back" "$([ "$now" = "$SECRET" ]; echo $?)"
}

# switch <label> <entry to make default> — drain, (write UKI,) set-default,
# reboot, Ready, uncordon, pods Ready; every phase timed
switch() {
	local label=$1 entry=$2 boot t0
	if [ "$DRAIN" = 1 ]; then
		t0=$SECONDS
		node "kubectl cordon $NODE >/dev/null && kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data --timeout=300s" > /dev/null 2>&1
		local_check "[$label] cordon + drain" $? ; timed "$label" "cordon + drain" $((SECONDS - t0))
	fi
	boot="$(node 'sync; cat /proc/sys/kernel/random/boot_id')"
	check "[$label] bootctl set-default $entry" "bootctl set-default '$entry' && bootctl status 2>/dev/null | grep -E 'Default Entry|Current Entry' ; ls -l /efi/EFI/Linux" || true
	log "  rebooting (boot id ${boot:0:8})"
	t0=$SECONDS
	node 'systemctl reboot' > /dev/null 2>&1 || true
	sleep 3
	wait_for "ssh on a new boot" "[ \"\$(cat /proc/sys/kernel/random/boot_id)\" != '$boot' ]" 900 || true
	timed "$label" "reboot → ssh on the new boot" $((SECONDS - t0))
	# NOT the Ready condition alone: across a ~20 s reboot the node lease never expires, so the API
	# keeps showing the pre-reboot Ready. kubelet reports the boot id it runs on; wait for that.
	wait_for "node Ready, reported by the kubelet of the new boot" "
		b=\$(cat /proc/sys/kernel/random/boot_id)
		[ \"\$(kubectl get node $NODE -o jsonpath='{.status.nodeInfo.bootID} {.status.conditions[?(@.type==\"Ready\")].status}')\" = \"\$b True\" ]" 900 || true
	timed "$label" "reboot → node Ready (kubelet of new boot)" $((SECONDS - t0))
	t0=$SECONDS
	[ "$DRAIN" = 1 ] && node "kubectl uncordon $NODE" > /dev/null
	wait_for "the pods Ready again" "kubectl -n $NS rollout status deploy/blob --timeout=5s && kubectl -n $NS rollout status sts/pg --timeout=5s && kubectl -n $NS exec pg-0 -- pg_isready -U postgres && kubectl -n $NS exec deploy/blob -- true" || true
	timed "$label" "uncordon → blob + Postgres Ready" $((SECONDS - t0))
}

# ---------------------------------------------------------------------------------------------------
log "update — $OLD_VER → the k3s in $(basename "$NEW_UKI")${EXPECT_NEW:+ (expected $EXPECT_NEW)}"
if [ -n "$EXPECT_NEW" ] && [ "$(minor "$EXPECT_NEW")" != "$(minor "$OLD_VER")" ]; then
	log "  a k3s MINOR change: the etcd snapshot below is the only way back for the datastore"
	node '[ -d /var/lib/rancher/k3s/server/db/etcd ]' || { log "  REFUSED: minor change on a node without etcd (no snapshot possible)"; exit 1; }
fi
if node '[ -d /var/lib/rancher/k3s/server/db/etcd ]'; then
	t0=$SECONDS
	check "k3s etcd-snapshot save (pre-update)" "k3s etcd-snapshot save --name pre-update 2>&1 | tail -2 && k3s etcd-snapshot ls 2>/dev/null | grep -q pre-update"
	timed update "etcd-snapshot save" $((SECONDS - t0))
else
	log "  datastore is not etcd (no cluster-init): no snapshot; fine within one minor"
fi
t0=$SECONDS
LOCAL_SHA="$(shasum -a 256 "$NEW_UKI" | awk '{print $1}')"
check "the ESP has room for a second UKI" "df -B1 --output=avail /efi | tail -1 | awk '{ exit \$1 < $(wc -c < "$NEW_UKI") * 1.1 }' && df -h /efi | tail -1" || exit 1
scp "${SSH_OPTS[@]}" -P "$PORT" -q "$NEW_UKI" "root@$HOST:/efi/EFI/Linux/.$NEW_ENTRY.tmp"
check "the new UKI is on the ESP as $NEW_ENTRY (sha256 matches)" "
	cd /efi/EFI/Linux && [ \"\$(sha256sum .$NEW_ENTRY.tmp | cut -d' ' -f1)\" = $LOCAL_SHA ] && mv .$NEW_ENTRY.tmp $NEW_ENTRY && sync && echo $LOCAL_SHA" || exit 1
timed update "copy UKI to the ESP" $((SECONDS - t0))

switch update "$NEW_ENTRY"
NEW_VER="$(node 'k3s --version | head -1' | awk '{print $3}')"
if [ "$SAME" = 1 ]; then
	log "  --same-version: $OLD_VER → $NEW_VER is NOT a version upgrade, only a reboot through the update path"
	local_check "k3s version unchanged, as --same-version says" "$([ "$NEW_VER" = "$OLD_VER" ]; echo $?)" "$NEW_VER"
else
	local_check "k3s version changed: $OLD_VER → $NEW_VER" "$([ "$NEW_VER" != "$OLD_VER" ] && { [ -z "$EXPECT_NEW" ] || [ "$NEW_VER" = "$EXPECT_NEW" ]; }; echo $?)" "$NEW_VER"
fi
verify "after update" "${EXPECT_NEW:-$NEW_VER}" "$NEW_ENTRY" "$ROWS"

# ---------------------------------------------------------------------------------------------------
if [ "$ROLLBACK" = 1 ]; then
	if [ "$(minor "$NEW_VER")" != "$(minor "$OLD_VER")" ]; then
		log "rollback — SKIPPED: $OLD_VER → $NEW_VER crosses a k3s minor; the old slot needs the etcd snapshot first"
	else
		log "rollback — back to $OLD_ENTRY, with state written under $NEW_VER"
		psql "insert into t select i, 'written-under-' || '$NEW_VER' from generate_series(10001, 10500) i" > /dev/null
		ROWS2="$(psql "$ROWS_Q")"
		log "  rows now $ROWS2"
		switch rollback "$OLD_ENTRY"
		verify "after rollback" "$OLD_VER" "$OLD_ENTRY" "$ROWS2"
	fi
fi

echo
echo "timings:"
printf '  %s\n' "${TIMES[@]}"
echo
printf '%s\n' "${RESULTS[@]}"
echo "PASS=$PASS FAIL=$FAIL  ($OLD_VER → $NEW_VER$([ "$SAME" = 1 ] && echo ', same version: NOT an upgrade'))"
[ "$FAIL" -eq 0 ]
