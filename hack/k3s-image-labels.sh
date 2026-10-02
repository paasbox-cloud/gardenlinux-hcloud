#!/usr/bin/env bash
# k3s-image-labels.sh — the snapshot name and labels of a Garden Linux k3s image.
#
#   hack/k3s-image-labels.sh name   <amd64|arm64> [<k3s version>]   gl-k3s-v1.36.4-amd64
#   hack/k3s-image-labels.sh labels <amd64|arm64> [<k3s version>]   the value for hcloud-upload-image --labels
#   hack/k3s-image-labels.sh --self-test
#
# The version defaults to K3S_VERSION in features/k3s/k3s.pin, i.e. what the image bakes; pass it when the
# build came from a tree with another pin (v1.36.3+k3s1).
#
# THE SCHEME (owner decision 2026-09-27):
#   gardener.cloud/image-name = gl-k3s-<vX.Y.Z>-<arch>   ONE value per k3s version AND architecture
#   gl-k3s                    = <vX.Y.Z>-k3sN            the full version; a label value cannot hold "+"
#   gl-flavor                 = hcloud-k3s_prod_usi-<arch>
#
# Why one name per version and architecture: pool-manager resolves ManagedServer.spec.imageRef to the
# NEWEST snapshot labeled gardener.cloud/image-name=<imageRef>, whatever its architecture or k3s. With a
# name shared across k3s versions, uploading a newer build silently changes what every later claim
# installs; with one shared across architectures, a claim can get the other architecture's disk. The management
# CLI that enrols pool servers refuses such a name, and a name that says no version.
# The k3s revision (+k3sN) is not in the name: a second revision of the same patch release shares it, so
# delete or relabel the older snapshot in that project before uploading the newer one.
#
# The public release's k3s UKI carries the same name (<name>.uki, .github/workflows/build.yml), so
# a node update by UKI URL, checked against the release's SHA256SUMS, names the same thing as the snapshot.
set -Eeuo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pin="$dir/features/k3s/k3s.pin"

die() { echo "k3s-image-labels: $*" >&2; exit 1; }

version_of() {
	local v="${1:-}"
	if [ -z "$v" ]; then
		v="$(sed -n 's/^K3S_VERSION=//p' "$pin")"
		[ -n "$v" ] || die "no K3S_VERSION in $pin"
	fi
	[[ "$v" =~ ^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]] || die "k3s version $v: want vX.Y.Z+k3sN"
	echo "$v"
}

arch_of() {
	case "${1:-}" in
		amd64 | arm64) echo "$1" ;;
		*) die "architecture ${1:-<none>}: want amd64 or arm64 (the Garden Linux names, not hcloud's x86/arm)" ;;
	esac
}

name() { local a v; a="$(arch_of "$1")"; v="$(version_of "${2:-}")"; echo "gl-k3s-${v%%+*}-$a"; }

labels() {
	local a v
	a="$(arch_of "$1")"
	v="$(version_of "${2:-}")"
	echo "gardener.cloud/image-name=$(name "$a" "$v"),gl-k3s=${v/+/-},gl-flavor=hcloud-k3s_prod_usi-$a"
}

self_test() {
	local fail=0
	expect() {
		if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; fail=1; fi
	}
	# A separate process: inside an `if`, errexit is off, so a die() in a command substitution would
	# not stop a function called from here.
	refuses() {
		if "$0" "$@" > /dev/null 2>&1; then echo "FAIL: accepted: $*"; fail=1; else echo "ok: refuses $*"; fi
	}
	expect "name amd64" "$(name amd64 v1.36.4+k3s1)" gl-k3s-v1.36.4-amd64
	expect "name arm64" "$(name arm64 v1.36.3+k3s1)" gl-k3s-v1.36.3-arm64
	expect "labels" "$(labels amd64 v1.36.4+k3s1)" \
		"gardener.cloud/image-name=gl-k3s-v1.36.4-amd64,gl-k3s=v1.36.4-k3s1,gl-flavor=hcloud-k3s_prod_usi-amd64"
	local pinned
	pinned="$(sed -n 's/^K3S_VERSION=//p' "$pin")"
	expect "default is the pin" "$(name arm64)" "gl-k3s-${pinned%%+*}-arm64"
	refuses name x86 v1.36.4+k3s1
	refuses name arm v1.36.4+k3s1
	refuses name amd64 v1.36.4
	refuses name amd64 1.36.4+k3s1
	# Hetzner label values: at most 63 characters, alphanumeric at both ends, [-_.] inside.
	local l
	for l in $(labels arm64 v1.36.4+k3s1 | tr ',' ' '); do
		if [[ "${l#*=}" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]{0,61}[A-Za-z0-9])?$ ]]; then
			echo "ok: label value ${l#*=}"
		else
			echo "FAIL: not a valid label value: $l"; fail=1
		fi
	done
	return "$fail"
}

case "${1:-}" in
	name) shift; name "$@" ;;
	labels) shift; labels "$@" ;;
	--self-test) self_test ;;
	*) sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2 ;;
esac
