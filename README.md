# MusicBar

A macOS menu bar app that shows the current track from Apple Music or Spotify.

MusicBar displays the album cover, track title, and artist next to a Dynamic Island-inspired waveform that reacts to the audio currently playing. It follows whichever player last reported activity, so switching between Apple Music and Spotify needs no configuration.

Requires macOS 14 or later.

## Controls

| Action | Result |
| --- | --- |
| Single click | Play or pause |
| Double click | Open the Music app |
| Option-click | Next track |
| Shift-click | Previous track |
| Scroll | Change the player's volume |
| Hover | Now-playing card with cover, title, artist, and progress |
| Right click | Menu: Open Music/Spotify, Favorite Song (Apple Music), Copy Song Link (Spotify), Settings, About, Quit |

## Features

- Works with Apple Music and Spotify, following whichever player last reported activity.
- Album cover thumbnail with a real waveform derived from Apple Music or Spotify's audio and frozen low while paused. Its color can use a gradient extracted from the current cover, one chosen color, or smoothly changing random colors. A music note appears when nothing is queued.
- Track title and artist shown in a fixed 150 pt width. Longer text holds for 10 seconds (or scrolls immediately on mouse hover), scrolls right to left to reveal the rest, then eases back and repeats.
- Slide and fade transitions on track change.
- Settings window with launch at login, player choice (automatic, Apple Music only, Spotify only), artwork/equalizer/artist toggles, hiding the title after a long pause, title width, auto-scroll delay, and the online artwork lookup.
- First-run explainer for the Automation permission, with a shortcut to System Settings if the permission was denied.
- VoiceOver label announces the current track and play state.
- Localized in English and Spanish.
- Audio capture stops while paused, hidden, with Reduce Motion on, or while the screen is locked or asleep to save battery, and restarts on its own when the output device changes.

## Build and run

```sh
./build.sh
open build/MusicBar.app
```

The build is ad-hoc signed by default, which changes its code signature on every build, so macOS may ask for permissions again after rebuilding. To keep them, sign with a stable identity: `SIGN_ID="Apple Development: …" ./build.sh`. The version comes from the latest `vX.Y` git tag.

On first use, macOS asks for permission to control the player (Automation) and to analyze its output (System Audio Recording). MusicBar reduces each live audio buffer to seven level values and never records or saves audio. If you decline by accident, re-enable MusicBar in System Settings → Privacy & Security. Real waveform capture requires macOS 14.2 or later.

## Start at login

Toggle "Launch at login" in MusicBar's settings (right-click → Settings…). The toggle registers the app at its current path, so if you move `build/MusicBar.app`, re-toggle the setting.

## How it works

- `StatusItemController` owns an `NSStatusItem` whose button hosts a SwiftUI view. Clicks pass through to the button so single and double clicks can be distinguished (a single click waits `NSEvent.doubleClickInterval`).
- Track changes arrive through distributed player notifications. AppleScript is used for the initial fetch, commands, launch/wake reconciliation, and a tolerant two-minute fallback in case a player notification is missed.
- A Core Audio process tap reads only the active player's output. PCM buffers are reduced to RMS levels at 15 Hz, discarded immediately, and drawn directly by a tiny AppKit view without invalidating the surrounding SwiftUI layout.
- If Apple Music does not expose artwork for a streaming track, MusicBar sends the current title and artist to Apple's iTunes Search API to find a cover (turn this off under Privacy in Settings). Artwork downloads are cached by the system and bounded to 20 MB.
