# Releasing remotely

The release pipeline produces independent `arm64` (Apple Silicon) and `x86_64`
(Intel) apps for macOS 14+. It uses ad-hoc signatures and does not require an
Apple Developer account, create certificates, notarize, install, or launch UI.

## Build

Use full Xcode with Swift 6.1 or later and the macOS SDK. The package's own
manifest uses Swift 5.10, but the locked dependency graph needs Swift 6.1+.
Both architectures can be cross-compiled on this Mac.

1. Edit the version and increasing build number in `Resources/Info.plist`.
2. Add `docs/releases/v<VERSION>.md`, including installation and upgrade notes.
3. Run `./scripts/validate_source.sh`, review the changes, and commit them.
4. Run `./scripts/release.sh` from a clean checkout.

For a single-architecture development check:

```sh
./scripts/release.sh --arch arm64
./scripts/release.sh --arch x86_64
```

Output is `dist/releases/<VERSION>/`:

- `remotely-<VERSION>-macos-arm64.dmg` and `.zip`
- `remotely-<VERSION>-macos-x86_64.dmg` and `.zip`
- `SHA256SUMS`, `BUILD_INFO.txt`, and `INSTALL.txt`

Logs are under `.build/release-logs/`. The script refuses to overwrite existing
downloads; move an older output directory aside before rebuilding. `clean.sh`
removes generated output while retaining the tracked `Package.resolved`.
Dependency updates are deliberate: resolve and review the lockfile, then commit
it before releasing. The protocol engine and SwiftProtobuf also have reviewed
commit pins in `build.sh`; the nine protocol patches must apply cleanly.

## Verify

```sh
./scripts/validate_release.sh dist/releases/<VERSION>
```

This extracts ZIPs, verifies and mounts DMGs read-only, checks app identities,
versions, minimum OS, exact architecture, ad-hoc signatures, resources, licenses,
system-only dynamic library references, and SHA-256 hashes. It runs `--version`
without opening UI or connecting to a TV. Intel execution uses Rosetta when
available; a missing execution environment is reported as a skipped smoke test.
Compiled Intel support still requires functional testing on an Intel Mac.

Before making the draft public, test downloaded/quarantined copies, first-launch
approval, local-network permission, Apple TV discovery and pairing, both remote
views, keyboard input, Now Playing, app launching, login items, and upgrading a
source-built installation. Keep macOS 14 and actual Intel testing in the release
checklist. Do not describe compiler smoke tests as full functional coverage.

## Upload a draft

Install [GitHub CLI](https://cli.github.com/) and authenticate the `introvertapp`
account using `gh auth login`. Then run:

```sh
./scripts/publish_release.sh
```

Publishing requires both architectures built from the current clean commit. It
pushes the current branch and creates a **draft** release targeting that exact
commit, with the four downloads and metadata attached. Review the branch's PR
and the draft's artifacts and notes before publishing on GitHub. It never
replaces an existing release or uploads with `--clobber`.

## Bundled notices

`Resources/ThirdParty/` contains notices copied from the pinned packages. The
protocol-core checkout declares MIT in its README but omits its linked LICENSE;
its bundled text uses the standard MIT terms with that README's copyright.
BigNum's BoringSSL notices retain the distinct original copyright/license
headers in its compiled source tree. Review these files when moving dependency
pins. No new license is applied to remotely's own code by this release work.
