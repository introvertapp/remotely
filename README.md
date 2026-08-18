<p align="center">
  <img alt="logo" src="docs/images/logo.png" width="640"/></br>
  A native macOS menu-bar remote for Apple TV, with Now Playing controls, app launching, keyboard input, and a compact MiniRemote.
</p>

<p align="center">
  <img
    alt="Version"
    src="https://img.shields.io/badge/dynamic/xml?url=https%3A%2F%2Fraw.githubusercontent.com%2Fintrovertapp%2Fremotely%2Fmain%2FResources%2FInfo.plist&query=%2F%2Fkey%5B.%3D%22CFBundleShortVersionString%22%5D%2Ffollowing-sibling%3A%3Astring%5B1%5D&prefix=v&label=version"
  >
</p>

## Features

- Full Apple TV remote with clickpad, navigation, playback, volume, and power controls
- Now Playing artwork and normalized local metadata, explicit MRP session switching, same-item metadata retention, teardown-only stale-session cleanup, seekable timeline, and standard transport controls
- MiniRemote for a compact always-available control surface
- Optional **Auto-skip tv ads and pre-roll sequences** using Apple TV’s published main-content boundary
- Launch installed Apple TV apps directly from macOS
- Keyboard Search when Apple TV requests text input
- Discover, pair, and switch between multiple Apple TVs
- Optional always-on-top mode and launch at login

## Build

```zsh
./scripts/build.sh
```

The build validates source, fetches pinned dependencies, builds, signs, installs to `/Applications`, and launches remotely.
