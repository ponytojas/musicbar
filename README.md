# MusicBar

A macOS menu bar app that shows the current track from Apple Music or Spotify.

MusicBar displays the album cover, track title, and artist next to a live three-bar equalizer that animates while music plays. It follows whichever player last reported activity, so switching between Apple Music and Spotify needs no configuration.

Requires macOS 14 or later.

## Controls

| Action | Result |
| --- | --- |
| Single click | Play or pause |
| Double click | Open the Music app |
| Option-click | Next track |
| Right click | Menu: Open Music/Spotify, Settings, About, Quit |

## Features

- Works with Apple Music and Spotify, following whichever player last reported activity.
- Album cover thumbnail with a live equalizer that animates while playing and freezes low while paused. A music note appears when nothing is queued.
- Track title and artist shown in a fixed 150 pt width. Longer text holds for 10 seconds (or scrolls immediately on mouse hover), scrolls right to left to reveal the rest, then eases back and repeats.
- Slide and fade transitions on track change.
- Settings window with launch at login, artwork/equalizer/artist toggles, title width, and auto-scroll delay.
- First-run explainer for the Automation permission, with a shortcut to System Settings if the permission was denied.
- VoiceOver label announces the current track and play state.
- Localized in English and Spanish.
- The equalizer pauses while the screen is locked or asleep to save battery.

## Build and run

```sh
./build.sh
open build/MusicBar.app
```

On the first play/pause, macOS asks for permission to control Music (Automation). If you decline by accident, re-enable it in System Settings → Privacy & Security → Automation → MusicBar.

## Start at login

Toggle "Launch at login" in MusicBar's settings (right-click → Settings…). The toggle registers the app at its current path, so if you move `build/MusicBar.app`, re-toggle the setting.

## How it works

- `StatusItemController` owns an `NSStatusItem` whose button hosts a SwiftUI view. Clicks pass through to the button so single and double clicks can be distinguished (a single click waits `NSEvent.doubleClickInterval`).
- Track changes arrive via the `com.apple.Music.playerInfo` distributed notification, so the app never polls. AppleScript is used only for the initial fetch, a 30-second reconciliation, and the play/pause command.
