# Security policy

This repository is a **release snapshot** of a component of PaaSbox, the managed Kubernetes platform for Hetzner
(https://paasbox.com). Development happens in a private monorepo; every release is published here as one
commit and one tag, and the same tag names the container image on `ghcr.io/paasbox-cloud/gardenlinux-hcloud`.

## Reporting a vulnerability

Please do **not** open a public issue. Report privately through
[GitHub security advisories](https://github.com/paasbox-cloud/gardenlinux-hcloud/security/advisories/new) or by e-mail to
security@paasbox.com (see https://paasbox.com/.well-known/security.txt). You will get an acknowledgement
within two business days and a fix or a mitigation plan within the response targets below.

## Supported versions and support period

| Version | Supported |
| --- | --- |
| the newest release tag | yes |
| the previous release tag | security fixes for 90 days after the newer tag |
| older tags | no |

Security updates for a supported tag are published as a new tag from the same line. The support period of the
component is the lifetime of the PaaSbox platform, at least five years from first publication, and every
component adopted servers need to keep working as nodes stays public under the wind-down promise at
https://paasbox.com/docs/leaving/.

## Response targets

- Actively exploited vulnerability: acknowledged the same business day, reported to the relevant authorities
  within 24 hours where the law requires it, fix or mitigation as fast as the fix can be built and drilled.
- Other vulnerabilities: acknowledged within two business days, fixed in the next release, or sooner for
  high severity.

## What is published with a release

GitHub Release assets built by `.github/workflows/build.yml`: disk images (`.raw.xz`), unified kernel images (`.uki`), ESP archives (`.esp.tar`), the root filesystem for Hetzner installimage (`.tar.xz`), the build manifests, and a `SHA256SUMS` over all of them. THESE ASSETS ARE NOT SIGNED: the sums are GitHub's own digests of what the workflow uploaded, not a signature. Treat the Secure Boot and OCI-signing material baked into the `_usi` flavors as development placeholders regenerated on every build, not as a trust root.

Release notes name fixed vulnerabilities by identifier.
