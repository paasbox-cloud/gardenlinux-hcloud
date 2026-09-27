#!/usr/bin/env bash
# Does a rootfs tarball's FILENAME say to installimage what we mean it to say?
#
# installimage parses the basename in whoami() (functions.sh) and three fields are load-bearing.
# Get one wrong and the failure is not a rejected filename — it is a box that installs the wrong
# way, or aborts in the rescue system after the disks have already been wiped.
#
#   field 1  picks the distro code path: it matches *suse*/*centos*/*ubuntu*/*arch*/*rocky*/
#            *alma*/*rhel* case-insensitively and DEFAULTS TO debian. "Gardenlinux" matches
#            nothing and therefore gets the Debian path, which is the right one for apt/dpkg.
#   field 2  becomes IMG_VERSION, and installimage does BASH ARITHMETIC on it in a dozen places
#            (debian.sh:116, functions.sh:1698, 2305, 3766, ...). A value like "2150.6.0" turns
#            each of those into a syntax error that evaluates FALSE, so the modern branch is
#            silently skipped. It has to be an integer.
#   -amd64-  is how IMG_ARCH is found, by a sed that needs the arch BETWEEN two dashes. When it
#            cannot be determined installimage aborts outright ("can not determine image arch
#            from filename"), so the arch may not be the last field.
#
# IT ALSO ACCEPTS A WHOLE `IMAGE` VALUE, not just a filename, because installimage derives the
# name from the value with a plain `basename` — pure string work on the last "/", with no idea
# that a URL has a query string. So a PRESIGNED URL cannot be used as IMAGE: an AWS-style
# X-Amz-Credential carries literal slashes (AK/20260913/nbg1/s3/aws4_request), basename returns
# the tail of the SIGNATURE, and installimage aborts on "can not determine image arch from
# filename" — in the rescue system, after the disks are already committed. Credentials in the
# URL's authority (https://user:token@host/.../Name-...-amd64-robot.tar.xz) survive basename
# untouched and are the only authenticated URL form that works.
#
# Usage: test/installimage-name.sh <filename-or-IMAGE-value> [...]
#        test/installimage-name.sh --self-test
set -Eeuo pipefail

# whoami()'s logic, not an approximation of it. Prints "IAM IMG_VERSION IMG_ARCH".
parse() {
	local base="${1##*/}" iam=debian lower
	# tr rather than ${base,,}: macOS still ships bash 3.2, where that expansion is a "bad
	# substitution" — it would leave iam=debian and pass a name containing "Ubuntu" unnoticed.
	lower="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
	case "$lower" in
		*suse*) iam=suse ;;
		*centos*) iam=centos ;;
		*ubuntu*) iam=ubuntu ;;
		*arch*) iam=archlinux ;;
		*rocky*) iam=rockylinux ;;
		*alma*) iam=almalinux ;;
		*rhel*) iam=rhel ;;
	esac
	local version arch
	version="$(cut -d- -f2 <<< "$base")"
	arch="$(sed 's/.*-\(32\|64\|i386\|amd64\|arm64\)-.*/\1/' <<< "$base")"
	case "$arch" in *-*) arch=unknown ;; esac
	printf '%s %s %s\n' "$iam" "$version" "$arch"
}

check() {
	local base="${1##*/}" iam version arch bad=0
	read -r iam version arch <<< "$(parse "$base")"
	echo "  $base"
	echo "    installimage would read: IAM=$iam IMG_VERSION=$version IMG_ARCH=$arch"
	[ "$iam" = debian ] || { echo "    FAIL: selects the $iam code path, not debian"; bad=1; }
	[[ "$version" =~ ^[0-9]+$ ]] || { echo "    FAIL: IMG_VERSION '$version' is not an integer — installimage does arithmetic on it"; bad=1; }
	case "$arch" in
		amd64|arm64|64|i386|32) ;;
		*) echo "    FAIL: IMG_ARCH resolved to '$arch'; installimage aborts on an undetectable arch"; bad=1 ;;
	esac
	case "$base" in
		*.tar|*.tar.gz|*.tgz|*.tar.bz|*.tbz|*.tbz2|*.tar.bz2|*.tar.xz|*.txz|*.tar.zst) ;;
		*) echo "    FAIL: not one of installimage's accepted archive types (tar, tgz, tbz, txz, zst)"; bad=1 ;;
	esac
	[ "$bad" = 0 ] && echo "    OK"
	return "$bad"
}

if [ "${1:-}" = --self-test ]; then
	bad=0
	echo "names that must PASS:"
	for n in "Gardenlinux-1300-2150-6-0-amd64-robot.tar.xz" \
	         "Gardenlinux-1300-2150-6-0-amd64-robot-k3s.tar.xz" \
	         "Gardenlinux-1300-2150-6-0-amd64-robot.tar" \
	         "Gardenlinux-1300-2200-0-0-arm64-robot.tar.gz" \
	         "/root/Gardenlinux-1300-2150-6-0-amd64-robot.tar.xz" \
	         "https://github.com/o/r/releases/download/v1/Gardenlinux-1300-2150-6-0-amd64-robot.tar.xz" \
	         "https://bot:tok@git.example.test/api/packages/p/generic/gl/1/Gardenlinux-1300-2150-6-0-amd64-robot.tar.xz"; do
		check "$n" || bad=1
	done
	echo "names that must FAIL:"
	for n in "baremetal-robot-gardener_prod-amd64-2150.6.0-abc12345.tar" \
	         "Gardenlinux-2150.6.0-amd64-robot.tar.xz" \
	         "Gardenlinux-1300-2150-6-0-robot-amd64.tar.xz" \
	         "Gardenlinux-1300-2150-6-0-amd64-robot.raw.xz" \
	         "GardenlinuxUbuntu-1300-x-amd64-robot.tar.xz" \
	         "https://s3.example.test/b/Gardenlinux-1300-2150-6-0-amd64-robot.tar.xz?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AK/20260913/nbg1/s3/aws4_request&X-Amz-Signature=dead"; do
		if check "$n"; then echo "    ^ this should NOT have passed"; bad=1; fi
	done
	[ "$bad" = 0 ] && echo "self-test OK" || { echo "self-test FAILED"; exit 1; }
	exit 0
fi

[ $# -gt 0 ] || { echo "usage: $0 <filename>... | --self-test" >&2; exit 2; }
bad=0
for f in "$@"; do check "$f" || bad=1; done
exit "$bad"
