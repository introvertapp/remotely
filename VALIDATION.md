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
- Switching playback between apps (for example YouTube → Apple TV) immediately discards the previous MRP session and refreshes to the new app without requiring a replay/re-entry action.
- Dismissing/closing the active Apple TV app immediately clears its Now Playing metadata and transport/seek capabilities; reopening it or opening another media app starts from a fresh Now Playing session.
- With full Now Playing or MiniRemote visible, Infuse/YouTube/Apple TV state self-corrects within the foreground verification cadence if tvOS misses a push; hiding remotely stops that verification traffic.
- Apple TV episode title/season/episode metadata remains visible through ads and recap/pre-roll segments for the same playback item.
- With **Auto-skip tv ads and pre-roll sequences** enabled, newly started supported content jumps once to Apple TV’s published main-content boundary; disabling the preference leaves playback untouched.
- Apps can be launched and Keyboard Search accepts text when requested by tvOS.
- Preferences, Apps, and Remote card transitions remain smooth.
- The built app installs to `/Applications/remotely.app`, relaunches cleanly, and retains saved preferences/pairing credentials.

- Apple TV episode metadata shows series title, season/episode, and episode title when locally published; generic video sources use their standard creator/artist field as the secondary line (for example a YouTube channel).
