# Vendored upstream: Garden Linux

This directory (`components/gardenlinux`) is a **vendored downstream** of [gardenlinux/gardenlinux](https://github.com/gardenlinux/gardenlinux).
`hack/vendor-upstream.sh` copies, verbatim at tag `$GL_TAG`:

- `build` — the build wrapper (pins the matching `ghcr.io/gardenlinux/builder` container image by commit, so the builder floats with `GL_TAG`; the [gardenlinux/builder](https://github.com/gardenlinux/builder) repo itself only seeded this repo's layout once, from `builder_example`, and is not vendored ongoing)
- `keyring.gpg` — validates `packages.gardenlinux.io` InRelease
- `requirements.defs` — the requirement defaults that `features/*/requirements.mod` override; the
  `build` wrapper bind-mounts it since 2150.11.0, and podman will not start the builder without it
- `features/<closure>` — everything under `features/` **except** `features/hcloud/`,
  `features/robot/`, `features/k3s/` and `features/zfs/` (ours). The script's `FEATURES` array lists the
  24-feature closure of every flavor: `{cloud, gardener, _prod, _usi}` for hcloud plus `{baremetal, metal}`
  for robot, which adds `openstackCloud` (`baremetal`, `metal` and `openstackCloud` joined the array in the
  2150.11.0 sync; until then they were left at the initial 2150.6.0 copy)
- `cert/` tooling — gencert/genefiauth/gengpg + configs (generated keys are gitignored)

Ours, never overwritten by the script: `features/hcloud/`, `features/robot/`, `features/k3s/`, `features/zfs/`, `get_repo|get_version|get_commit|get_timestamp`, `build.config`, `.github/`, `test/`, `hack/`.

## The iron rule

**Never edit vendored files in place — bump `GL_TAG` and re-run `hack/vendor-upstream.sh`.**
This rule is stated in `hack/vendor-upstream.sh` (header, "NEVER EDIT VENDORED FILES IN PLACE")
and `README.md` § "Layout: ours vs vendored". Local deltas live exclusively in our own files
listed above.

## Re-vendor flow (what a Renovate bump PR means)

A Renovate PR bumping the marker below is a **signal, not a mergeable change**. Never merge it
as-is. Instead it triggers the Garden Linux train in the (private) landscape repo:

1. Bump `GL_TAG` in `hack/vendor-upstream.sh` (default at the top) **and** the pins in
   `get_version` + `get_timestamp` (epoch = `1585612800 + <major> * 86400`), then run:

   ```sh
   GL_TAG=<new-tag> hack/vendor-upstream.sh
   # or reuse a checkout already at the tag:
   GL_SRC=/path/to/gardenlinux hack/vendor-upstream.sh
   ```

   Recompute the `FEATURES` closure in the script if upstream's feature graph changed.
2. Tripwire: if the GL release notes show **containerd 2.3+** (config v4), Gardener must be
   ≥ v1.144 first (README).
3. Build all flavors, upload to the lab project, run `test/run-tests.sh` (both archs) and the
   pet-rebuild test — GL releases every 2–5 weeks, the suite runs on every image update.
4. Consumer side (landscape repo): upload snapshots labeled
   `gardener.cloud/image-name=gardenlinux-<version>`, boot-test, then flip the CloudProfile /
   pool image ref. Only then close the Renovate PR (superseded by the real vendor commit) or
   update the marker in the vendor commit itself.
5. Commit the vendor sync as `chore(vendor): Garden Linux <tag> ...`, including the marker
   update below so Renovate sees the new current value.

## Release watch marker

Renovate (self-hosted, the root `renovate.json` custom regex manager) watches upstream tags via
this block. Upstream tags are the bare version since the 2150 line (3-segment,
e.g. `2150.6.0`); legacy 2-segment (`1877.20`) and `beta_*` tags are excluded by strict
semver versioning.

<!-- renovate: datasource=github-tags depName=gardenlinux/gardenlinux -->
vendored-upstream: 2150.11.0
