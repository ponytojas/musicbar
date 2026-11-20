# MusicBar

A macOS menu bar app that shows the current track from Apple Music or Spotify.

MusicBar displays the album cover, track title, and artist next to a small equalizer that reacts to the audio currently playing. It follows whichever player is playing, so switching between Apple Music and Spotify needs no configuration.

Requires macOS 14.2 or later.

## Controls

| Action | Result |
| --- | --- |
| Click | Play or pause, at once |
| Option-click | Next track |
| Shift-click | Previous track |
| Scroll | Change the player's volume |
| Hover | Now-playing card with cover, title, artist, album, and a progress bar you can click or drag to seek. Controls: previous, play/pause, next, shuffle, repeat, volume; for Apple Music also favorite, add to playlist, and AirPlay output |
| Right click or Control-click | Menu: Open Music/Spotify, Favorite Song and Show in Music (Apple Music), Copy Song Link (Spotify), Recently Played, Sleep Timer, Check for Updates, Settings, About, Quit |
| ⌃⌥⌘M | Show or hide the card, ready for the keyboard |
| ⌃⌥⌘F | Favorite or unfavorite the song (Apple Music) |
| ⌃⌥⌘P | Add the song to a playlist (Apple Music) |

The three shortcuts can be changed or cleared in Settings → Shortcuts, where Play or pause, Next Track, and Previous Track can be given one too. A shortcut another app already uses is flagged there.

A card opened with its shortcut takes key presses: Space plays or pauses, ← and → change track, ↑ and ↓ change the volume, F favorites, S shuffles, R repeats, and Esc closes it.

Double-clicking can open the player instead (Settings → Menu Bar). It is off by default because telling a double click from a single one means every single click has to wait about half a second.

## Features

- Works with Apple Music and Spotify. A player that starts playing takes over the menu bar; one that is merely paused or idle doesn't displace the one that is playing.
- Album cover thumbnail and an equalizer that is frozen low while paused. It comes in three styles: frequency bands (bass on the left), loudness, or simulated movement that never listens to audio and so needs no recording permission. Its color can use a gradient extracted from the current cover (kept readable on a light or dark menu bar), one chosen color, or smoothly changing random colors. A music note appears when nothing is queued.
- Track title and artist take only the room they need, up to a width you choose (150 pt by default). Longer text holds for 10 seconds (or scrolls immediately on mouse hover), scrolls right to left to reveal the rest, then eases back and repeats while music plays. The title, artist, cover, and equalizer can each be hidden, down to a cover-only item.
- Slide and fade transitions on track change.
- Recently Played lists the last ten songs. Choosing one plays it again: any Spotify song, and Apple Music songs that are in your library. A song that can't be started is copied to the clipboard as "title — artist" instead.
- Sleep timer: pause after 15, 30, or 60 minutes, or when the current song ends. A small moon in the menu bar shows one is running, and a countdown survives quitting MusicBar.
- Optional notification when the song changes, with the cover and a Next Track button; handy while the menu bar is hidden in full screen.
- Settings window with launch at login, player choice (automatic, Apple Music only, Spotify only), what the menu bar shows, pointer behavior (hover card, scroll volume, double click), equalizer style and colors, shortcuts, notifications, update checks, and the online artwork lookup.
- First-run explainer for the Automation permission. If the permission is missing later, the menu's first item says so and opens the right pane of System Settings.
- VoiceOver announces the current track and play state, and the item's Actions menu offers next, previous, the card, and the menu. Reduce Motion replaces the scrolling title and sliding transitions with a still title and short fades.
- Localized in English and Spanish, including the system's permission prompts.
- Audio capture stops while paused, hidden, with Reduce Motion on, or while the screen is locked or asleep to save battery, and restarts on its own when the output device changes.

## Build and run

```sh
./build.sh
open build/MusicBar.app
```

| Option | Effect |
| --- | --- |
| `--universal` | Build for both Apple silicon and Intel |
| `--debug` | Debug build: quicker to compile, with symbols for a debugger |
| `--run` | Quit a running copy and launch the new build |

The build is ad-hoc signed by default, which changes its code signature on every build, so macOS may ask for permissions again after rebuilding. To keep them, sign with a stable identity: `SIGN_ID="Apple Development: …" ./build.sh`. The version comes from the latest `vX.Y` git tag.

On first use, macOS asks for permission to control the player (Automation) and, unless the equalizer is hidden or simulated, to analyze its output (System Audio Recording). MusicBar reduces the audio to seven level values and never records or saves it. If you decline by accident, re-enable MusicBar in System Settings → Privacy & Security. When MusicBar can't listen, the equalizer falls back to simulated movement and the menu says so.

### Development

MusicBar is a Swift package, but it only works as an app bundle: the permission prompts, notifications, launch at login, and localization all need the `Info.plist` and resources that `build.sh` puts around the binary. So instead of `swift run`, use:

```sh
./build.sh --debug --run     # rebuild and relaunch
swift test                   # unit tests
log stream --predicate 'subsystem == "com.ponytojas.musicbar"'
```

To debug, attach to the running app (`lldb -n MusicBar`, or Xcode's Debug → Attach to Process).

## Releases and updates

Pushing a `vX.Y` tag runs the release workflow, which builds a universal app and publishes it as a GitHub release. Releases are not notarized yet, so macOS blocks the first launch until you approve the app under System Settings → Privacy & Security.

MusicBar can look for a newer release: Check for Updates in the menu, or once a day if you turn that on in Settings. It only reads the latest release's version from GitHub and offers to open the download page; nothing is installed on its own.

## Start at login

Toggle "Launch at login" in MusicBar's settings (right-click → Settings…). The toggle registers the app at its current path, so if you move `build/MusicBar.app`, re-toggle the setting.

## How it works

- `StatusItemController` owns an `NSStatusItem` whose button hosts a SwiftUI view, and holds the state: what is playing, its cover, the equalizer. Its extensions cover the card's controls (`+Card`), clicks, scrolling and shortcuts (`+Input`), and the context menu (`+Menu`).
- Track changes arrive through distributed player notifications. AppleScript is used for the initial fetch, commands, launch/wake reconciliation, and a tolerant two-minute fallback in case a player notification is missed. Scripts run on one dedicated thread, off the main thread, each with a timeout, and only talk to a player that is running (a bare `tell` would relaunch one that just quit).
- A Core Audio process tap reads only the active player's output. For frequency bands, the last 2048 samples go through an FFT and are grouped into seven bands; for loudness, each buffer is reduced to RMS levels. Either way seven numbers are published at 15 Hz, the samples are discarded, and a tiny AppKit view draws the bars without invalidating the surrounding SwiftUI layout.
- If Apple Music does not expose artwork for a streaming track, MusicBar sends the current title and artist to Apple's iTunes Search API to find a cover (turn this off under Privacy in Settings). Covers are only downloaded over https from Apple's and Spotify's image servers, streamed with a 20 MB cap, and cached by the system.

## Network use

MusicBar contacts the network for three things, each of which can be avoided: Spotify covers (downloaded from Spotify's image server), the iTunes Search lookup described above (Settings → General → Privacy), and update checks (off unless you turn them on or use the menu item).
