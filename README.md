# MusicBar

macOS menu bar app showing the current track from Apple Music or Spotify.

- **Single click** the menu bar item → play/pause
- **Double click** → open the Music app
- **Option-click** → next track
- **Right click** → menu (Open Music/Spotify, Settings…, About, Quit)
- Native settings window: launch at login, artwork/equalizer/artist toggles,
  title width, auto-scroll delay
- Spotify supported alongside Apple Music — follows whichever player last
  reported activity
- First-run explainer for the Automation permission, with a shortcut to
  System Settings if denied
- VoiceOver label announces the current track and play state
- Localized in English and Spanish
- Equalizer pauses while the screen is locked or asleep (battery)
- Track title + artist shown in a fixed 150 pt width; longer text holds 10 s
  (or scrolls immediately on mouse hover), scrolls right-to-left to reveal the
  rest, then eases back and repeats
- Album cover thumbnail plus a live 3-bar equalizer (animates while playing,
  freezes low while paused); music note symbol when nothing is queued
- Slide/fade transitions on track change

## Build & run

```sh
./build.sh
open build/MusicBar.app
```

Requires macOS 14+. On the first play/pause, macOS asks for permission to
control Music (Automation). If you decline by accident, re-enable it in
System Settings → Privacy & Security → Automation → MusicBar.

## Start at login

Toggle "Launch at login" in MusicBar's settings (right-click → Settings…).
Note: it registers the app at its current path — if you move
`build/MusicBar.app`, re-toggle the setting.

## How it works

- `StatusItemController` owns an `NSStatusItem` whose button hosts a SwiftUI
  view; clicks pass through to the button so single/double click can be
  distinguished (single click waits `NSEvent.doubleClickInterval`).
- Track changes arrive via the `com.apple.Music.playerInfo` distributed
  notification — no polling. AppleScript is used only for the initial fetch,
  a 30 s reconciliation, and the play/pause command.
