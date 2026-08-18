# remotely v1.2.10 source bundle

Base repository snapshot: `introvertapp/remotely` commit `fc573fe5985db38312002182a2bf66066f4c87a1`.

Intentional v1.2.10 changes:

- `Patches/protocol-core-now-playing-verification.patch`
  - scopes periodic teardown replies to the exact playback snapshot and authoritative-state revision that issued the request;
  - protects every explicit non-stopped playback state, including paused;
  - requires two consecutive stopped/empty confirmations for identity-poor fallback teardown evidence;
  - preserves the existing two-second visible Now Playing verification timer.
- `Resources/Info.plist`: version 1.2.10, build 17.
- `scripts/build.sh`: updated verifier post-patch assertions and v1.2.10 summary.
- `scripts/validate_source.sh`: v1.2.10 verifier assertions plus byte-for-byte baselines for unchanged first-party Swift source and unchanged protocol patches.

Explicitly not included: the separate stale explicit playback-queue response fix planned for v1.2.11.

Binary resource note: the connected GitHub API available to this build session exposes the repository's binary AppIcon only as a non-streamable blob. `Resources/AppIcon.icns` in this archive is therefore a build-valid neutral fallback, not a source-code change. Preserve the repository's existing `Resources/AppIcon.icns` when applying this source bundle to the working repository.
