#!/usr/bin/env bash
# k3s-pin.sh — keep features/k3s in step with what it copies from elsewhere.
#
#   hack/k3s-pin.sh check [--online]   the pin and the bootstrap values agree with the monorepo
#   hack/k3s-pin.sh update <version>   re-pin to a k3s release (writes version + both sha256)
#
# check compares, and fails on any difference:
#   1. K3S_VERSION in features/k3s/k3s.pin  ==  runtime.k3s in deploy/versions.yaml
#   2. the lvm-localpv HelmChart's valuesContent  ==  pool-manager/examples/storage/localpv-lvm/values.yaml
#      (comments and blank lines ignored)
#   3. with --online: the pinned sha256s  ==  the release's sha256sum-<arch>.txt
# 1 and 2 need the monorepo around this component; in the public export (this directory alone)
# they are reported as skipped, not passed.
#
# The monorepo CI runs `check` (offline) on every change to components/gardenlinux or deploy/versions.yaml,
# so a Renovate bump of runtime.k3s is red until someone runs `update` here — the image and the
# bootstrap then move together, and the new checksums are reviewed in the same change.
set -Eeuo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pin="$dir/features/k3s/k3s.pin"
chart="$dir/features/k3s/file.include/usr/share/k3s/manifests/image-lvm-localpv.yaml"
versions="$dir/../../deploy/versions.yaml"
values="$dir/../pool-manager/examples/storage/localpv-lvm/values.yaml"

sums_url() { echo "https://github.com/k3s-io/k3s/releases/download/${1//+/%2B}/sha256sum-$2.txt"; }
asset() { case "$1" in amd64) echo k3s ;; arm64) echo k3s-arm64 ;; esac; }
release_sum() { curl -fsSL --retry 3 "$(sums_url "$1" "$2")" | awk -v a="$(asset "$2")" '$2 == a { print $1 }'; }
pinned() { sed -n "s/^$1=//p" "$pin"; }

case "${1:-}" in
	check)
		bad=0
		version="$(pinned K3S_VERSION)"
		if [ -f "$versions" ]; then
			want="$(awk '/^runtime:/ { r = 1; next } r && /^[^[:space:]#]/ { r = 0 } r && $1 == "k3s:" { gsub(/"/, "", $2); print $2 }' "$versions")"
			if [ "$version" = "$want" ]; then
				echo "ok: k3s.pin $version == deploy/versions.yaml runtime.k3s"
			else
				echo "FAIL: k3s.pin says $version, deploy/versions.yaml runtime.k3s says ${want:-<absent>} — run: hack/k3s-pin.sh update $want"
				bad=1
			fi
		else
			echo "skipped: deploy/versions.yaml not found (public export) — the pin is not compared"
		fi

		if [ -f "$values" ]; then
			strip() { sed 's/[[:space:]]*#.*$//; /^[[:space:]]*$/d'; }
			a="$(strip < "$values")"
			b="$(sed -n '/^  valuesContent: |-$/,$p' "$chart" | tail -n +2 | sed 's/^    //' | strip)"
			if [ "$a" = "$b" ]; then
				echo "ok: image-lvm-localpv.yaml valuesContent == pool-manager localpv-lvm/values.yaml"
			else
				echo "FAIL: image-lvm-localpv.yaml valuesContent differs from pool-manager localpv-lvm/values.yaml:"
				diff <(echo "$a") <(echo "$b") || true
				bad=1
			fi
		else
			echo "skipped: pool-manager values.yaml not found (public export) — the chart values are not compared"
		fi

		if [ "${2:-}" = --online ]; then
			for arch in amd64 arm64; do
				got="$(release_sum "$version" "$arch")"
				if [ "$got" = "$(pinned "K3S_SHA256_$arch")" ]; then
					echo "ok: $version $arch sha256 matches the release"
				else
					echo "FAIL: $version $arch — pinned $(pinned "K3S_SHA256_$arch"), release ${got:-<absent>}"
					bad=1
				fi
			done
		fi
		exit "$bad"
		;;
	update)
		version="${2:?usage: hack/k3s-pin.sh update <version, e.g. v1.36.4+k3s1>}"
		for arch in amd64 arm64; do
			sum="$(release_sum "$version" "$arch")"
			[[ "$sum" =~ ^[0-9a-f]{64}$ ]] || { echo "no sha256 for $version $arch at $(sums_url "$version" "$arch")" >&2; exit 1; }
			sed -i.bak "s/^K3S_SHA256_$arch=.*/K3S_SHA256_$arch=$sum/" "$pin"
			echo "K3S_SHA256_$arch=$sum"
		done
		sed -i.bak "s/^K3S_VERSION=.*/K3S_VERSION=$version/" "$pin"
		rm -f "$pin.bak"
		echo "K3S_VERSION=$version — review the diff of $pin, then rebuild the k3s flavors"
		;;
	*)
		sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//' >&2
		exit 2
		;;
esac
