import AppKit
import SwiftUI

/// Shown once, on the first launch: most of what the item does is behind a
/// modifier key or a gesture nothing on screen hints at. Also reachable
/// from the menu as Tips.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let openSettings: () -> Void

    private static let shownKey = "didShowWelcome"

    init(openSettings: @escaping () -> Void) {
        self.openSettings = openSettings
    }

    func showOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: Self.shownKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.shownKey)
        show()
    }

    func show() {
        if window == nil {
            let view = WelcomeView(
                cardShortcut: AppSettings.shared.globalShortcuts
                    ? AppSettings.shared.shortcuts[.toggleCard]?.displayText
                    : nil,
                onSettings: { [weak self] in
                    self?.window?.close()
                    self?.openSettings()
                },
                onDone: { [weak self] in self?.window?.close() }
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = NSLocalizedString("Welcome to MusicBar", comment: "")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

struct WelcomeView: View {
    /// The card's shortcut as shown to the user; nil when it has none.
    let cardShortcut: String?
    let onSettings: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MusicBar lives in your menu bar")
                    .font(.title2.weight(.semibold))
                Text("It shows what Apple Music or Spotify is playing. Here is what the item does:")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                tip("playpause.fill", "Click to play or pause.")
                tip("forward.fill", "Option-click for the next track, Shift-click for the previous one.")
                tip("speaker.wave.2.fill", "Scroll over it to change the player's volume.")
                tip("rectangle.portrait.on.rectangle.portrait.fill", "Hover for the card: seek, shuffle, repeat, favorite, playlists.")
                tip("filemenu.and.cursorarrow", "Right-click for the menu: recently played, sleep timer, settings.")
                if let cardShortcut {
                    tip("keyboard.fill", "\(cardShortcut) shows the card from anywhere, ready for the keyboard.")
                }
            }

            HStack {
                Button("Open Settings", action: onSettings)
                Spacer()
                Button("Got It", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func tip(_ systemImage: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
