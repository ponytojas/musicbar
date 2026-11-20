# Changelog

## Unreleased

### Changed

- A click now plays or pauses at once. Double-click-to-open-the-player is an option in Settings, off by default, because it made every single click wait about half a second.
- The title takes only the room it needs, up to the chosen maximum width, instead of always filling it. Turn "Shrink to fit short titles" off for the previous fixed width.
- The equalizer shows frequency bands (bass on the left) by default. The previous loudness display is still available as a style.
- A paused or idle player no longer takes the menu bar away from the one that is playing.
- The settings window is organized into General, Menu Bar, Equalizer, and Shortcuts tabs.
- Long titles scroll on their own only while music plays; hovering still scrolls them when paused.
- Requires macOS 14.2 (was 14.0, where the equalizer could never work).
- Song-change notifications arrive once the cover is known, so they can show it.

### Added

- Control-click opens the menu, like a right click.
- Configurable global shortcuts, with optional ones for play/pause, next, and previous; a shortcut taken by another app is flagged.
- The card opened with its shortcut can be used from the keyboard (Space, arrows, F, S, R, Esc).
- Card: album name, a volume slider, drag-to-seek on the progress bar, and tooltips with the full title.
- Simulated equalizer style that needs no audio permission, used automatically when MusicBar can't listen to the player.
- Recently Played songs play again when chosen (Spotify, and Apple Music library songs), and the list can be cleared.
- Sleep timer option "When the Song Ends", a moon indicator in the menu bar, and countdowns that survive a relaunch.
- Notifications show the cover and have a Next Track button.
- Menu items that appear when a permission is missing and open the right pane of System Settings.
- Check for Updates, and an optional daily check.
- Settings to hide the title, turn off the hover card, and turn off scrolling to change volume.
- VoiceOver actions on the menu bar item; Reduce Motion is honored by the title and transitions.
- Spanish and English text for the system permission prompts.
- `./build.sh --universal`, `--debug`, and `--run`; a release workflow that publishes tagged builds.
- The layered app icon (Liquid Glass on macOS 26) is compiled into the app.

### Fixed

- A player stuck on a dialog could freeze every later command for two minutes; scripts now time out.
- Scripts only talk to a player that is running, so a request caught mid-quit can't relaunch it.
- The Automation prompt no longer blocks the app while it waits for an answer.
- A Spotify-only listener's first click no longer opens Apple Music: the last player used is remembered.
- Two versions of a song with the same title and artist no longer share a cover and favorite state.
- A song without a cover is looked up twice at most, not on every reconcile.
- A state request made while another was in flight is no longer dropped, and an older reading can't overwrite a newer notification.
- Favoriting from the menu or shortcut toggled the wrong way when the state wasn't loaded yet.
- Trackpad momentum kept changing the volume after the fingers lifted.
- Downloads are capped while streaming rather than after the whole body arrived, and only come from known image servers.
- Dark covers could make the equalizer bars invisible on a dark menu bar.
- ⌘W and ⌘Q now work in the settings window.
- The notification switch no longer stays on when macOS has notifications turned off for MusicBar.

## 1.1

- Interactive hover card: playback controls, favorite, add to playlist, click-to-seek, shuffle and repeat, AirPlay output.
- Context menu: Show in Music, recently played songs, sleep timer.
- Global keyboard shortcuts.
- Optional notification when the song changes.
- Scroll over the item to change volume; Shift-click for the previous track.
- Settings: follow one player only, collapse to the note icon after a long pause, turn off the online artwork lookup.
