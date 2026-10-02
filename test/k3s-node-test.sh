#!/usr/bin/env bash
# k3s-node-test.sh — the k3s image checks (features/k3s/README.md "Testing"), against ONE booted node
# reachable over SSH as root, whose role is `server`. Where the node runs does not matter: QEMU
# (test/k3s-qemu.sh drives this script), Apple Virtualization.framework (vz), an hcloud server, a Robot box.
#
#   test/k3s-node-test.sh --host <ip> [--port 22] [--key <file>] [--checks image,1,guard,2,3] [--timeout 900]
#
#   image  the image is what the flavor promises: k3s pinned + symlinks, roles off-by-image, k3s
#          check-config, modules/sysctls, cgroup v2, LSM, /var a partition of its own and /etc an
#          overlay whose upper layer is in /var (_usi), vg0 present, the metadata guard's rule in place
#   1      k3s is Ready; `kubectl get sc` shows local-lvm-thin as the ONLY default; LocalPV-LVM runs
#   guard  the metadata guard: a pod gets no answer from 169.254.169.254, the host does (where there is a
#          metadata service at all; without one — QEMU — only the pod half is checked, and it says so)
#   2      a 1Gi PVC becomes a 1Gi logical volume in vg0; writing 2Gi into it fails at the cap
#   3      reboot: the node comes back Ready, and the cluster state (a Secret, a Deployment) and the
#          PVC's data are still there
#
# Checks 4 and 5 (in-place update, rollback) are test/k3s-update-test.sh; it needs a second UKI.
# Check 6 (several nodes) and the OCI half of gardenlinux-update are in features/k3s/README.md.
#
# Exit status: 0 when every check passed. Leaves its test objects in namespace k3s-image-test
# (delete it, or throw the node away).
set -u -o pipefail

HOST="" PORT=22 KEY="" CHECKS="image,1,guard,2,3" TIMEOUT=900
while [ $# -gt 0 ]; do case "$1" in
	--host) HOST=$2; shift 2 ;;
	--port) PORT=$2; shift 2 ;;
	--key) KEY=$2; shift 2 ;;
	--checks) CHECKS=$2; shift 2 ;;
	--timeout) TIMEOUT=$2; shift 2 ;;
	*) echo "unknown arg $1" >&2; exit 2 ;;
esac; done
[ -n "$HOST" ] || { echo "--host required" >&2; exit 2; }

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR -p "$PORT")
[ -n "$KEY" ] && SSH_OPTS+=(-i "$KEY")
PASS=0 FAIL=0 RESULTS=()

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
node() { ssh "${SSH_OPTS[@]}" "root@$HOST" "$@"; }
# check <name> <remote shell snippet> — run on the node; pass on exit 0. Output is shown indented.
check() {
	local name=$1 out rc
	out="$(node "$2" 2>&1)"; rc=$?
	[ -n "$out" ] && sed 's/^/      /' <<< "$out"
	if [ $rc -eq 0 ]; then PASS=$((PASS + 1)); RESULTS+=("PASS $name"); log "  PASS $name"
	else FAIL=$((FAIL + 1)); RESULTS+=("FAIL $name"); log "  FAIL $name"; fi
	return $rc
}
# wait_for <what> <remote snippet> [timeout] — poll until the snippet succeeds.
wait_for() {
	local what=$1 snippet=$2 limit=${3:-$TIMEOUT} start=$SECONDS
	log "  waiting for $what (≤${limit}s)"
	until node "$snippet" > /dev/null 2>&1; do
		[ $((SECONDS - start)) -ge "$limit" ] && { log "  timed out waiting for $what"; return 1; }
		sleep 5
	done
	log "  $what after $((SECONDS - start))s"
}
want() { [[ ",$CHECKS," == *",$1,"* ]]; }

wait_for "ssh" true 600 || exit 1

if want image; then
	log "check image — what the flavor promises"
	check "k3s is the pinned release, with kubectl/crictl/ctr" '
		k3s --version | head -1
		for t in kubectl crictl ctr; do [ "$(readlink /usr/bin/$t)" = k3s ] || { echo "$t is not a k3s symlink"; exit 1; }; done'
	check "exactly one k3s role is enabled — the one provisioning chose ($(node k3s-role show 2>/dev/null | xargs))" '
		# the image ships both disabled (exec.config fails the build otherwise); provisioning enabled one
		[ "$(k3s-role show | wc -l)" -eq 1 ]
		systemctl cat k3s.service | grep -q "^ExecStartPre=/usr/libexec/k3s/sync-manifests"'
	check "k3s check-config passes" '
		k3s check-config > /tmp/check-config.txt 2>&1; rc=$?
		grep -E "^(STATUS|- cgroup hierarchy|- /usr/sbin/iptables|- CONFIG_(OVERLAY_FS|BRIDGE_NETFILTER|VXLAN|NF_CONNTRACK)=|.*missing)" /tmp/check-config.txt | sed "s/\x1b\[[0-9;]*m//g" | head -20
		exit $rc'
	check "kernel/sysctl prerequisites (cgroup v2, modules incl. dm_thin_pool, ip_forward, AppArmor)" '
		set -e
		[ "$(stat -fc %T /sys/fs/cgroup)" = cgroup2fs ]
		for m in overlay br_netfilter nf_conntrack dm_thin_pool; do [ -d /sys/module/$m ]; done
		[ "$(sysctl -n net.ipv4.ip_forward)" = 1 ]
		[ "$(sysctl -n net.bridge.bridge-nf-call-iptables)" = 1 ]
		grep -q apparmor /sys/kernel/security/lsm
		echo "lsm=$(cat /sys/kernel/security/lsm) iptables=$(iptables --version)"'
	check "/var is its own persistent partition; /etc persists in it (_usi) or on the root fs (classic)" '
		set -e
		findmnt -no SOURCE,FSTYPE /var
		if [ "$(findmnt -no FSTYPE /)" = erofs ]; then
			[ "$(findmnt -no SOURCE /var)" = "$(realpath /dev/disk/by-partlabel/VAR)" ]
			[ "$(findmnt -no FSTYPE /etc)" = overlay ]
			findmnt -no OPTIONS /etc | grep -q "upperdir=[^,]*/var/etc.overlay"
			[ -f /var/etc.overlay/rancher/k3s/config.yaml ]   # provisioning wrote it; it lives in /var
			echo "_usi: / is erofs (in the UKI), /var = partlabel VAR, /etc upper layer in /var"
		fi'
	check "the image's own units are enabled (vg0, thin-pool monitor, stop-pods, persist-root-keys)" '
		for u in k3s-vg0.service k3s-thinpool-monitor.timer k3s-stop-pods.service k3s-persist-root-keys.service lvm2-monitor.service; do
			[ "$(systemctl is-enabled $u)" = enabled ] || { echo "$u is not enabled"; exit 1; }
		done'
	check "the metadata guard is enabled, active, required by both roles, and its rule is in place" '
		set -e
		[ "$(systemctl is-enabled metadata-guard.service)" = enabled ]
		systemctl is-active metadata-guard.service
		for u in k3s.service k3s-agent.service; do
			systemctl show -p Requires --value "$u" | grep -qw metadata-guard.service || { echo "$u does not require it"; exit 1; }
		done
		iptables -w -t raw -C PREROUTING -d 169.254.169.254/32 -m comment --comment metadata-guard -j DROP
		iptables -w -t raw -S PREROUTING'
	check "vg0 exists (k3s-vg0.service), thin-pool policy 80/20 resolves" '
		set -e
		systemctl is-active k3s-vg0.service
		vgs --units g vg0
		[ "$(lvmconfig activation/thin_pool_autoextend_threshold | tr -dc 0-9)" = 80 ]'
fi

if want 1; then
	log "check 1 — k3s Ready, the LVM class is the only default"
	wait_for "node Ready" 'kubectl get nodes --no-headers | grep -qw Ready' || true
	check "node is Ready" 'kubectl get nodes -o wide'
	# every container of the controller and the node plugin ready — under TCG the sidecars restart a few
	# times on "context deadline exceeded" before the API server and the CSI socket answer in time
	openebs_ready='[ "$(kubectl -n openebs get pods --no-headers 2>/dev/null | grep -c .)" -ge 2 ] && kubectl -n openebs get pods --no-headers | grep -v Completed | awk "{ split(\$2, r, \"/\"); if (r[1] != r[2] || \$3 != \"Running\") bad=1 } END { exit bad }"'
	wait_for "LocalPV-LVM controller and node plugin ready" "$openebs_ready" || true
	check "local-lvm-thin is the ONLY default StorageClass" '
		kubectl get sc
		d="$(kubectl get sc -o jsonpath="{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class==\"true\")]}{.metadata.name}{\"\n\"}{end}")"
		[ "$d" = local-lvm-thin ]'
	check "LocalPV-LVM is installed from the image's HelmChart and running" '
		kubectl -n kube-system get helmchart lvm-localpv -o jsonpath="{.spec.chart} {.spec.version}{\"\n\"}"
		kubectl -n openebs get pods
		'"$openebs_ready"
fi

if want guard; then
	log "check guard — pods cannot read the metadata service, the host can"
	# host: the instance id from the hcloud metadata service (empty where there is none)
	host_md="$(node 'curl -fsS -m 5 http://169.254.169.254/hetzner/v1/metadata/instance-id 2>/dev/null' || true)"
	# pod: the same request from the pod network, and — to prove the pod has a network at all — the API
	# server through its ClusterIP (answers 401/403 without credentials: "server returned error")
	guard_pod='kubectl -n default delete pod mdguard --ignore-not-found --wait=true >/dev/null 2>&1
		kubectl -n default run mdguard --image=busybox:1.37 --restart=Never --command -- sh -c "wget -T 5 -q -O- http://169.254.169.254/hetzner/v1/metadata/instance-id; echo md_rc=\$?; wget -T 5 -q -O- --no-check-certificate https://kubernetes.default.svc/version; echo api_rc=\$?" >/dev/null
		for i in $(seq 1 60); do p=$(kubectl -n default get pod mdguard -o jsonpath="{.status.phase}"); [ "$p" = Succeeded ] || [ "$p" = Failed ] && break; sleep 2; done
		kubectl -n default logs mdguard 2>&1; kubectl -n default delete pod mdguard --wait=false >/dev/null 2>&1'
	pod_out="$(node "$guard_pod" 2>&1)"
	sed 's/^/      /' <<< "$pod_out"
	if [ -n "$host_md" ]; then
		check "the host reads the metadata service (instance-id $host_md)" 'true'
	else
		check "the host reads the metadata service — SKIPPED: no metadata service here (not hcloud)" 'true'
	fi
	# judged here, not on the node: the verdict is about the output above
	verdict="exit 0"
	if grep -q 'md_rc=0' <<< "$pod_out"; then verdict="echo 'the pod READ the metadata service'; exit 1"
	elif ! grep -q 'timed out' <<< "$pod_out"; then verdict="echo 'no timeout from the metadata request'; exit 1"
	elif ! grep -qE 'api_rc=0|server returned error|gitVersion' <<< "$pod_out"; then
		verdict="echo 'the pod has no network at all, so the timeout proves nothing'; exit 1"
	fi
	check "a pod gets no answer from 169.254.169.254 (timed out), while it reaches the API server" "$verdict"
fi

if want 2; then
	log "check 2 — a 1Gi PVC is a 1Gi LV in vg0, capped"
	node 'kubectl create namespace k3s-image-test --dry-run=client -o yaml | kubectl apply -f - >/dev/null
	cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data, namespace: k3s-image-test}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: holder, namespace: k3s-image-test}
spec:
  replicas: 1
  selector: {matchLabels: {app: holder}}
  template:
    metadata: {labels: {app: holder}}
    spec:
      terminationGracePeriodSeconds: 1
      containers:
        - name: c
          image: busybox:1.37
          command: [sh, -c, "sleep 2147483647"]
          volumeMounts: [{name: d, mountPath: /data}]
      volumes: [{name: d, persistentVolumeClaim: {claimName: data}}]
EOF'
	wait_for "the PVC to bind and the pod to run" 'kubectl -n k3s-image-test get pvc data -o jsonpath="{.status.phase}" | grep -qx Bound && kubectl -n k3s-image-test get pods -l app=holder --no-headers | grep -q Running' || true
	check "the PVC is a 1Gi thin logical volume in vg0" '
		set -e
		pv="$(kubectl -n k3s-image-test get pvc data -o jsonpath="{.spec.volumeName}")"
		echo "PV $pv"
		lvs --units b -o lv_name,vg_name,lv_size,pool_lv,segtype vg0
		[ "$(lvs --noheadings --units b --nosuffix -o lv_size "vg0/$pv" | tr -d " ")" = 1073741824 ]'
	check "writing 2Gi into it fails at the cap (ENOSPC)" '
		out="$(kubectl -n k3s-image-test exec deploy/holder -- sh -c "dd if=/dev/zero of=/data/fill bs=1M count=2048 2>&1; echo rc=\$?; df -m /data | tail -1")"
		echo "$out"
		rm_out="$(kubectl -n k3s-image-test exec deploy/holder -- rm -f /data/fill)"
		grep -q "No space left on device" <<< "$out" && ! grep -q "^rc=0" <<< "$out"'
fi

if want 3; then
	log "check 3 — state survives a reboot"
	node 'kubectl -n k3s-image-test create secret generic survivor --from-literal=marker=before-reboot --dry-run=client -o yaml | kubectl apply -f - >/dev/null
		kubectl -n k3s-image-test exec deploy/holder -- sh -c "echo before-reboot > /data/marker && sync"' || true
	boot_before="$(node 'cat /proc/sys/kernel/random/boot_id')"
	log "  rebooting (boot id ${boot_before:0:8})"
	node 'systemctl reboot' > /dev/null 2>&1 || true
	sleep 10
	wait_for "ssh after reboot" "[ \"\$(cat /proc/sys/kernel/random/boot_id)\" != \"$boot_before\" ]" 900 || true
	wait_for "node Ready after reboot" 'kubectl get nodes --no-headers | grep -qw Ready' || true
	# NOT the pod's phase: right after the reboot the API still shows the pre-reboot "Running" and the
	# node's pre-reboot Ready until kubelet reports again. An exec only works once kubelet and the
	# container are really back.
	wait_for "the Deployment's pod answering again" 'kubectl -n k3s-image-test exec deploy/holder -- true' || true
	check "the node rebooted and is Ready" "[ \"\$(cat /proc/sys/kernel/random/boot_id)\" != \"$boot_before\" ] && kubectl get nodes"
	check "the Secret survived" '[ "$(kubectl -n k3s-image-test get secret survivor -o jsonpath="{.data.marker}" | base64 -d)" = before-reboot ]'
	check "the PVC's data survived" '[ "$(kubectl -n k3s-image-test exec deploy/holder -- cat /data/marker)" = before-reboot ]'
	check "root's SSH key survived (k3s-persist-root-keys)" 'grep -c . /etc/ssh/authorized_keys.d/root'
	check "the metadata guard's rule is back after the reboot" 'iptables -w -t raw -C PREROUTING -d 169.254.169.254/32 -m comment --comment metadata-guard -j DROP'
fi

echo
printf '%s\n' "${RESULTS[@]}"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
