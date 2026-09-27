#!/usr/bin/env bash
# vendor-upstream.sh — sync the vendored Garden Linux bits this config dir builds on.
#
# WHY VENDORING: gardenlinux/builder mounts ONLY the config dir's own features/ into the build
# container (see `build`: `-v .../features/$f:/builder/features/$f:ro`), and parse_features asserts
# that EVERY feature referenced by an include/exclude edge exists locally. builder_example is fully
# self-contained (it builds plain Debian); to build actual Garden Linux we must carry the upstream
# feature tree for the closure of our flavors. Copies (not submodule/symlinks) keep the repo
# split-out-ready (this dir is destined to become its own public repo) and CI-trivial.
#
# WHAT IT VENDORS from github.com/gardenlinux/gardenlinux @ $GL_TAG:
#   - build            (the build wrapper, verbatim — pins the matching ghcr.io/gardenlinux/builder image)
#   - keyring.gpg      (validates packages.gardenlinux.io InRelease; NOT the Debian archive keyring)
#   - features/<closure>  (see FEATURES below)
#   - cert/ tooling    (gencert/genefiauth/gengpg + Makefile + *.conf templates + Containerfile + build;
#                       needed because features/_usi/exec.post bakes cert/oci-sign.crt +
#                       cert/secureboot.{pk,null.pk,kek,db}.auth into the image. Generated certs/keys
#                       are .gitignored — only the tooling is committed.)
#
# NEVER EDIT VENDORED FILES IN PLACE — change $GL_TAG and re-run. Local deltas live exclusively in
# features/hcloud/ (our platform feature), the get_* pins, build.config and the workflow.
#
# Usage:  hack/vendor-upstream.sh            (clones upstream at $GL_TAG into a temp dir)
#         GL_SRC=/path/to/checkout hack/vendor-upstream.sh   (reuse an existing checkout, must be at $GL_TAG)
set -euo pipefail

GL_TAG="${GL_TAG:-2150.6.0}"   # GL0: line = 2150.x; keep in sync with ./get_version
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# FEATURES = transitive include+exclude closure of {cloud, gardener, _prod, _usi} at 2150.6.0
# (our `hcloud` platform feature includes `cloud`; flavors add gardener,_prod[,_usi]).
# Recompute when bumping GL_TAG:
#   python3 - walk features/*/info.yaml from the seed set following features.include+exclude.
FEATURES=(
  _fwcfg _legacy _nocrypt _nopkg _prod _selinux _slim _unsigned _usi
  base cloud firewall gardener iscsi log multipath nvme openstackMetal sap server ssh
)

CERT_TOOLING=(
  Makefile Containerfile build gencert genefiauth gengpg gpg.conf
  root-ca.conf intermediate-ca.conf kernel-sign.conf oci-sign.conf tpm-sign.conf
  secureboot.pk.conf secureboot.kek.conf secureboot.db.conf
)

if [ -n "${GL_SRC:-}" ]; then
  src="$GL_SRC"
  [ "$(git -C "$src" describe --tags 2>/dev/null)" = "$GL_TAG" ] || {
    echo "FATAL: GL_SRC=$src is not at tag $GL_TAG" >&2; exit 1; }
else
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  git clone --depth 1 --branch "$GL_TAG" https://github.com/gardenlinux/gardenlinux.git "$tmp/gardenlinux"
  src="$tmp/gardenlinux"
fi

echo "vendoring from gardenlinux @ $GL_TAG ($src)"

cp "$src/build" "$dir/build" && chmod +x "$dir/build"
cp "$src/keyring.gpg" "$dir/keyring.gpg"

mkdir -p "$dir/features"
for f in "${FEATURES[@]}"; do
  rm -rf "$dir/features/$f"
  cp -a "$src/features/$f" "$dir/features/$f"
done

mkdir -p "$dir/cert"
for f in "${CERT_TOOLING[@]}"; do
  cp -a "$src/cert/$f" "$dir/cert/$f"
done

echo "done. vendored: build, keyring.gpg, ${#FEATURES[@]} features, cert tooling."
echo "reminder: features/hcloud/, get_*, build.config, .github/ are OURS — never overwritten here."
