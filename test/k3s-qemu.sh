#!/usr/bin/env bash
# k3s-qemu.sh — boot a k3s flavor's .raw under QEMU as a single-node server and run
# test/k3s-node-test.sh against it. Linux only (QEMU + UEFI firmware + cloud-localds).
#
#   test/k3s-qemu.sh <image.raw> [--arch arm64|amd64] [--disk 40G] [--mem 6144] [--cpus 4]
#                    [--port 2222] [--checks image,1,2,3] [--dns <resolver>] [--keep]
#
# The .raw is never modified: the VM runs on a qcow2 overlay grown to --disk, so systemd-repart lays
# out /var and vg0 on first boot exactly as on a fresh hcloud server. KVM is used when /dev/kvm exists
# and the guest arch is the host's; otherwise TCG. Under TCG the node boots and check "image" passes,
# but LocalPV-LVM's CSI calls time out on the emulated CPU (measured in an OrbStack machine, which has
# no KVM) — for checks 1–3 use KVM, or boot the .raw on a Mac with Virtualization.framework (ownpaas'
# vz backend) and point test/k3s-node-test.sh at it.
#
# Provisioning is what an hcloud server gets, through the NoCloud datasource (a `cidata` seed; the
# image's datasource_list is Hetzner, NoCloud, None): user data that puts the key on ROOT (Hetzner's
# vendor data does the same with default_user=root), writes /etc/rancher/k3s/config.yaml and runs
# `k3s-role server --now`. Plus one thing only a VM outside Hetzner needs: the hcloud element pins DNS
# to Hetzner's recursors, which answer only inside Hetzner, so the seed adds a networkd drop-in with
# --dns (default: QEMU's user-net resolver 10.0.2.3).
#
# --keep leaves the VM running (and prints how to reach it) instead of powering it off at the end.
set -Eeuo pipefail

RAW="" ARCH="" DISK=40G MEM=6144 CPUS=4 PORT=2222 CHECKS="image,1,2,3" DNS=10.0.2.3 KEEP=0
while [ $# -gt 0 ]; do case "$1" in
	--arch) ARCH=$2; shift 2 ;;
	--disk) DISK=$2; shift 2 ;;
	--mem) MEM=$2; shift 2 ;;
	--cpus) CPUS=$2; shift 2 ;;
	--port) PORT=$2; shift 2 ;;
	--checks) CHECKS=$2; shift 2 ;;
	--dns) DNS=$2; shift 2 ;;
	--keep) KEEP=1; shift ;;
	-*) echo "unknown arg $1" >&2; exit 2 ;;
	*) RAW=$1; shift ;;
esac; done
[ -f "$RAW" ] || { echo "usage: $0 <image.raw> [options]" >&2; exit 2; }
if [ -z "$ARCH" ]; then
	case "$RAW" in *-arm64-*) ARCH=arm64 ;; *-amd64-*) ARCH=amd64 ;; *) echo "--arch needed" >&2; exit 2 ;; esac
fi
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK="$(mktemp -d)"
QEMU_PID=""
cleanup() {
	if [ "$KEEP" = 0 ] && [ -n "$QEMU_PID" ]; then kill "$QEMU_PID" 2> /dev/null || true; wait "$QEMU_PID" 2> /dev/null || true; fi
	[ "$KEEP" = 0 ] && rm -rf "$WORK"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N "" -f "$WORK/key"
qemu-img create -q -f qcow2 -F raw -b "$(realpath "$RAW")" "$WORK/disk.qcow2" "$DISK"

cat > "$WORK/user-data" <<EOF
#cloud-config
# What Hetzner's vendor data sets on a real hcloud server: the platform key goes to root.
system_info:
  default_user:
    name: root
disable_root: false
ssh_authorized_keys:
  - $(cat "$WORK/key.pub")
write_files:
  - path: /etc/systemd/network/99-default.network.d/60-outside-hetzner-dns.conf
    content: |
      # test VM only: Hetzner's recursors do not answer outside Hetzner
      [Network]
      DNS=
      DNS=$DNS
  - path: /etc/rancher/k3s/config.yaml
    permissions: "0600"
    content: |
      # the node's own settings — the image's defaults are in config.yaml.d/00-image.yaml
      write-kubeconfig-mode: "0600"
      node-label:
        - image-test=true
runcmd:
  - [networkctl, reload]
  - [k3s-role, server, --now]
EOF
printf 'instance-id: k3s-qemu-%s\nlocal-hostname: k3s-qemu\n' "$(date +%s)" > "$WORK/meta-data"
cloud-localds "$WORK/seed.img" "$WORK/user-data" "$WORK/meta-data"

accel=(-accel "tcg,thread=multi")
case "$ARCH" in
	arm64)
		qemu="qemu-system-aarch64"
		[ -e /dev/kvm ] && [ "$(uname -m)" = aarch64 ] && accel=(-accel kvm)
		# NOT -cpu max under TCG: with it AAVMF never got past its banner in 10 minutes (QEMU 10.2,
		# measured 2026-09-23); cortex-a72 boots the image to k3s pods in about three.
		cpu=cortex-a72; [ "${accel[1]}" = kvm ] && cpu=host
		machine=(-M virt -cpu "$cpu")
		code=/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd vars=/usr/share/AAVMF/AAVMF_VARS.fd
		;;
	amd64)
		qemu="qemu-system-x86_64"
		[ -e /dev/kvm ] && [ "$(uname -m)" = x86_64 ] && accel=(-accel kvm)
		cpu=max; [ "${accel[1]}" = kvm ] && cpu=host
		machine=(-M q35 -cpu "$cpu")
		code=/usr/share/OVMF/OVMF_CODE_4M.fd vars=/usr/share/OVMF/OVMF_VARS_4M.fd
		;;
esac
cp "$vars" "$WORK/vars.fd"

"$qemu" "${machine[@]}" "${accel[@]}" -smp "$CPUS" -m "$MEM" \
	-drive if=pflash,format=raw,readonly=on,file="$code" \
	-drive if=pflash,format=raw,file="$WORK/vars.fd" \
	-drive if=virtio,format=qcow2,file="$WORK/disk.qcow2" \
	-drive if=virtio,format=raw,file="$WORK/seed.img" \
	-netdev user,id=n0,hostfwd=tcp:127.0.0.1:"$PORT"-:22 -device virtio-net-pci,netdev=n0 \
	-device virtio-rng-pci \
	-display none -serial file:"$WORK/serial.log" -monitor none &
QEMU_PID=$!
echo "VM ${accel[1]} pid $QEMU_PID, serial log $WORK/serial.log, ssh -i $WORK/key -p $PORT root@127.0.0.1"

rc=0
"$here/k3s-node-test.sh" --host 127.0.0.1 --port "$PORT" --key "$WORK/key" --checks "$CHECKS" --timeout 1800 || rc=$?

if [ "$KEEP" = 1 ]; then
	echo "kept: ssh -i $WORK/key -p $PORT root@127.0.0.1   (kill $QEMU_PID when done; files in $WORK)"
fi
exit "$rc"
