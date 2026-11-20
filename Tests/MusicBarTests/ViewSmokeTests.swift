import AppKit
import SwiftUI
import XCTest
@testable import MusicBar

/// Builds each SwiftUI surface once. These catch a view that traps or
/// collapses when it is laid out, which unit tests of the logic can't.
@MainActor
final class ViewSmokeTests: XCTestCase {
    private func fittingSize(of view: some View) -> NSSize {
        NSHostingView(rootView: view).fittingSize
    }

    private func sampleModel(title: String) -> TrackModel {
        let model = TrackModel()
        model.update(title: title, artist: "Artist", album: "Album", isPlaying: true)
        model.progress = PlaybackProgress(position: 72, duration: 215, start: Date().addingTimeInterval(-72))
        model.isFavorited = true
        model.playbackModes = PlaybackModes(shuffle: true, repeatMode: .one)
        model.volume = 65
        model.playlists = [Playlist(id: "0A", name: "Road Trip")]
        model.outputDevices = [
            OutputDevice(id: "00", name: "Mac", isSelected: true),
            OutputDevice(id: "01", name: "HomePod", isSelected: false),
        ]
        return model
    }

    func testSettingsTabsLayOut() {
        let settings = AppSettings.shared
        XCTAssertGreaterThan(fittingSize(of: SettingsView(settings: settings)).height, 100)
        for size in [
            fittingSize(of: GeneralSettings(settings: settings)),
            fittingSize(of: MenuBarSettings(settings: settings)),
            fittingSize(of: EqualizerSettings(settings: settings)),
            fittingSize(of: ShortcutSettings(settings: settings)),
            fittingSize(of: HistorySettings(settings: settings, history: ListeningHistory(fileURL: nil))),
            fittingSize(of: HistorySettings(settings: settings, history: ListeningHistory(fileURL: nil, plays: [
                Play(title: "Song", artist: "Artist", album: "Album", player: "com.apple.Music", date: Date()),
            ]))),
        ] {
            XCTAssertGreaterThan(size.width, 100)
            XCTAssertGreaterThan(size.height, 100)
        }
    }

    func testWelcomeLaysOutWithAndWithoutAShortcut() {
        let with = fittingSize(of: WelcomeView(cardShortcut: "⌃⌥⌘M", onSettings: {}, onDone: {}))
        let without = fittingSize(of: WelcomeView(cardShortcut: nil, onSettings: {}, onDone: {}))
        XCTAssertEqual(with.width, 440)
        // The shortcut tip is only there when a shortcut is.
        XCTAssertGreaterThan(with.height, without.height)
    }

    func testCardKeepsItsSizeWhateverIsLoaded() {
        let actions = PopupActions(
            playPause: {}, previous: {}, next: {}, toggleFavorite: {}, addToPlaylist: { _ in },
            seek: { _ in }, setVolume: { _ in }, changeVolume: { _ in },
            toggleShuffle: {}, cycleRepeat: {}, selectOutput: { _ in }
        )
        let loaded = fittingSize(of: HoverPopupView(model: sampleModel(title: "Song"), actions: actions))

        // Before the details arrive: no progress, modes, volume or lists.
        let bare = TrackModel()
        bare.update(title: "A much longer title than the card is wide", artist: "", album: "", isPlaying: false)
        let unloaded = fittingSize(of: HoverPopupView(model: bare, actions: actions))

        XCTAssertGreaterThan(loaded.width, 150)
        XCTAssertEqual(loaded, unloaded)
    }

    func testMenuBarItemGivesBackRoomForShortTitles() throws {
        try XCTSkipUnless(AppSettings.shared.fitTitleToContent && AppSettings.shared.showTitle)
        let waveform = AudioWaveformModel()
        let progress = MenuBarProgressModel()
        let short = fittingSize(of: StatusBarView(model: sampleModel(title: "Hi"), waveform: waveform, progress: progress))
        let long = fittingSize(of: StatusBarView(
            model: sampleModel(title: "A title far too long to fit in the menu bar at any width"),
            waveform: waveform,
            progress: progress
        ))
        XCTAssertLessThan(short.width, long.width)
        // The long one stops at the configured width plus its fixed parts.
        XCTAssertLessThan(long.width, AppSettings.shared.textWidth + 80)
    }

    /// macOS hides a status item that can't shrink into the room beside
    /// the notch. With the cover, a long title and the time left all on,
    /// the item must still be able to give way: by narrowing the title.
    func testMenuBarItemShrinksInsteadOfDisappearingWhenShortOfRoom() {
        let settings = AppSettings.shared
        settings.resetToDefaults()
        defer { settings.resetToDefaults() }
        settings.menuBarProgress = .remaining

        let model = sampleModel(title: "A title far too long to fit in the menu bar at any width")
        let pixel = NSImage(size: NSSize(width: 68, height: 68), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        model.artwork = pixel
        model.sleepTimerActive = true
        let progress = MenuBarProgressModel()
        progress.remaining = 151
        let controller = NSHostingController(
            rootView: StatusBarView(model: model, waveform: AudioWaveformModel(), progress: progress)
        )

        let wanted = controller.sizeThatFits(in: NSSize(width: 10_000, height: 22)).width
        XCTAssertGreaterThan(wanted, settings.textWidth + 60, "cover, equalizer and time sit beside a full-width title")

        // Offered less, it takes what it is offered…
        for offered in [wanted - 23, wanted - 60, wanted - 100] {
            XCTAssertEqual(controller.sizeThatFits(in: NSSize(width: offered, height: 22)).width, offered, accuracy: 0.5)
        }
        // …until only the minimum title is left; the other parts don't give.
        let smallest = controller.sizeThatFits(in: NSSize(width: 0, height: 22)).width
        XCTAssertEqual(smallest, wanted - settings.textWidth + MarqueeText.minimumWidth, accuracy: 0.5)

        // A title shorter than the minimum asks for no more than itself.
        model.update(title: "Hi", artist: "", album: "", isPlaying: true)
        let shortTitle = NSHostingController(
            rootView: StatusBarView(model: model, waveform: AudioWaveformModel(), progress: progress)
        )
        XCTAssertLessThan(shortTitle.sizeThatFits(in: NSSize(width: 0, height: 22)).width, smallest)
    }
}
