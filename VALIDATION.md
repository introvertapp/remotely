# Validation

The source includes automated invariants for the native UI, Apple TV protocol integration, build pipeline, signing, installation, MiniRemote, Now Playing, keyboard input, and presentation behavior.

Run:

```zsh
./scripts/validate_source.sh
```

For a release build, `./scripts/build.sh` runs the same validation automatically before fetching dependencies or compiling.

## Manual release checks

Before publishing a release, verify on macOS that:

- Apple TV discovery and pairing work from Preferences.
- Remote and MiniRemote controls respond correctly.
- Now Playing metadata, artwork, seeking, and transport controls update correctly.
- Apps can be launched and Keyboard Search accepts text when requested by tvOS.
- Preferences, Apps, and Remote card transitions remain smooth.
- The built app installs to `/Applications/remotely.app`, relaunches cleanly, and retains saved preferences/pairing credentials.
