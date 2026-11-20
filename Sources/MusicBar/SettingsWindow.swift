import AppKit
import os
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: .shared))
            let window = NSWindow(contentViewController: hosting)
            window.title = NSLocalizedString("MusicBar Settings", comment: "")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            // The window is recreated on each open; restore its last position.
            window.setFrameAutosaveName("SettingsWindow")
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Drop the window (and its SwiftUI hierarchy) once closed instead of
    /// keeping it alive for the rest of the app's life.
    func windowWillClose(_ notification: Notification) {
        // Closing mid-recording would leave the global shortcuts off.
        ShortcutRecording.cancel()
        window = nil
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        TabView {
            GeneralSettings(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            MenuBarSettings(settings: settings)
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            EqualizerSettings(settings: settings)
                .tabItem { Label("Equalizer", systemImage: "waveform") }
            ShortcutSettings(settings: settings)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        // Short enough for a 13-inch screen at its largest text size; each
        // tab scrolls if it ever needs more.
        .frame(width: 460, height: 500)
        .padding(.top, 8)
    }
}

/// Small grey explanation under a section.
private struct Footnote: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

struct GeneralSettings: View {
    @ObservedObject var settings: AppSettings
    @State private var loginItemStatus = SMAppService.mainApp.status
    @State private var launchAtLogin = [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    @State private var notificationsDenied = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
                Picker("Player", selection: $settings.playerMode) {
                    Text("Automatic").tag(PlayerMode.automatic)
                    Text(verbatim: "Apple Music").tag(PlayerMode.appleMusic)
                    Text(verbatim: "Spotify").tag(PlayerMode.spotify)
                }
            } footer: {
                if loginItemStatus == .requiresApproval {
                    HStack {
                        Footnote("Approve MusicBar in Login Items to finish.")
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                }
            }

            Section {
                Toggle("Notify when the song changes", isOn: $settings.notifyOnTrackChange)
                    .onChange(of: settings.notifyOnTrackChange) { _, enabled in
                        guard enabled else { return }
                        notificationsDenied = false
                        Task {
                            guard !(await TrackNotifier.requestAuthorization()) else { return }
                            // Don't leave the switch on for banners macOS
                            // will never show.
                            notificationsDenied = true
                            settings.notifyOnTrackChange = false
                        }
                    }
            } header: {
                Text("Notifications")
            } footer: {
                if notificationsDenied {
                    HStack {
                        Footnote("Notifications are turned off for MusicBar in System Settings.")
                        Spacer()
                        Button("Open Notification Settings") { TrackNotifier.openSystemSettings() }
                            .controlSize(.small)
                    }
                }
            }

            Section {
                Toggle("Check for updates automatically", isOn: $settings.checkForUpdatesAutomatically)
                LabeledContent("Version") {
                    Text(verbatim: UpdateChecker.currentVersion)
                }
            } header: {
                Text("Updates")
            } footer: {
                Footnote("Asks GitHub for the latest release once a day. You can also check from the menu.")
            }

            Section {
                Toggle("Look up missing artwork online", isOn: $settings.lookUpArtworkOnline)
            } header: {
                Text("Privacy")
            } footer: {
                Footnote("Sends the song title and artist to Apple's iTunes Search when Music has no cover.")
            }
        }
        .formStyle(.grouped)
        // Pick up an approval granted in System Settings meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItemStatus = SMAppService.mainApp.status
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Logger.musicBar.error("Launch at login change failed: \(error.localizedDescription, privacy: .public)")
            launchAtLogin = [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
        }
        loginItemStatus = SMAppService.mainApp.status
    }
}

struct MenuBarSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Show album artwork", isOn: $settings.showArtwork)
                Toggle("Show title", isOn: $settings.showTitle)
                Toggle("Show artist name", isOn: $settings.showArtist)
                    .disabled(!settings.showTitle)
                Toggle("Hide when no player is open", isOn: $settings.hideWhenNoPlayer)
            } header: {
                Text("Show")
            } footer: {
                if settings.hideWhenNoPlayer {
                    Footnote("While it's hidden, open MusicBar again from Finder or Spotlight to get back to these settings.")
                }
            }

            Section {
                Toggle("Shrink to fit short titles", isOn: $settings.fitTitleToContent)
                LabeledContent("Maximum title width") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Slider(value: $settings.textWidth, in: 100...250, step: 10)
                            .frame(width: 170)
                        Text("\(Int(settings.textWidth)) pt")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Picker("Auto-scroll after", selection: $settings.holdSeconds) {
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                    Text("20 seconds").tag(20)
                    Text("30 seconds").tag(30)
                }
                Picker("Hide title when paused", selection: $settings.collapseAfterPauseMinutes) {
                    Text("Never").tag(0)
                    Text("After 1 minute").tag(1)
                    Text("After 5 minutes").tag(5)
                    Text("After 15 minutes").tag(15)
                }
            } header: {
                Text("Title")
            } footer: {
                Footnote("Long titles scroll on their own while music plays, and whenever you hover the menu bar item.")
            }
            .disabled(!settings.showTitle)

            Section {
                Toggle("Show the card on hover", isOn: $settings.showHoverCard)
                Toggle("Scroll to change the volume", isOn: $settings.scrollChangesVolume)
                Toggle("Double-click opens the player", isOn: $settings.doubleClickOpensPlayer)
            } header: {
                Text("Pointer")
            } footer: {
                Footnote("With double-click on, a single click waits a moment before it plays or pauses, to tell the two apart.")
            }
        }
        .formStyle(.grouped)
    }
}

struct EqualizerSettings: View {
    @ObservedObject var settings: AppSettings

    private var styleNote: LocalizedStringKey {
        switch settings.equalizerStyle {
        case .spectrum: "Bass on the left, treble on the right, from the player's own audio."
        case .levels: "How loud the player's audio is, moment to moment."
        case .simulated: "Decorative movement. MusicBar doesn't listen to any audio, so macOS asks for no recording permission."
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show equalizer", isOn: $settings.showEqualizer)
                Picker("Style", selection: $settings.equalizerStyle) {
                    Text("Frequency bands").tag(EqualizerStyle.spectrum)
                    Text("Loudness").tag(EqualizerStyle.levels)
                    Text("Simulated").tag(EqualizerStyle.simulated)
                }
                .disabled(!settings.showEqualizer)
                LabeledContent("Sensitivity") {
                    Slider(value: $settings.equalizerSensitivity, in: 0.5...2, step: 0.1) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("Low").font(.caption).foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Text("High").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(width: 220)
                }
                .disabled(!settings.showEqualizer)
            } footer: {
                Footnote(styleNote)
            }

            Section {
                Picker("Position", selection: $settings.equalizerPosition) {
                    Text("Left of title").tag(EqualizerPosition.left)
                    Text("Right of title").tag(EqualizerPosition.right)
                }
                Picker("Color", selection: $settings.equalizerColorMode) {
                    Text("Gradient").tag(EqualizerColorMode.gradient)
                    Text("Fixed color").tag(EqualizerColorMode.fixed)
                    Text("Random colors").tag(EqualizerColorMode.random)
                }
                if settings.equalizerColorMode == .fixed {
                    ColorPicker("Custom color", selection: Binding(
                        get: { settings.equalizerColor },
                        set: { settings.equalizerColor = $0 }
                    ), supportsOpacity: false)
                }
            }
            .disabled(!settings.showEqualizer)
        }
        .formStyle(.grouped)
    }
}

struct ShortcutSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Global shortcuts", isOn: $settings.globalShortcuts)
            }

            Section {
                ForEach(HotKeyAction.allCases, id: \.self) { action in
                    ShortcutRow(action: action, settings: settings)
                }
            } footer: {
                Footnote("Click a shortcut, then press the new keys with ⌃, ⌥ or ⌘. Delete clears it and Esc cancels.")
            }
            .disabled(!settings.globalShortcuts)
        }
        .formStyle(.grouped)
        .onDisappear { ShortcutRecording.cancel() }
    }
}

private struct ShortcutRow: View {
    let action: HotKeyAction
    @ObservedObject var settings: AppSettings

    private var isRecording: Bool { settings.recordingShortcut == action }

    var body: some View {
        LabeledContent(action.title) {
            HStack(spacing: 6) {
                if settings.unavailableShortcuts.contains(action), !isRecording {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help(Text("Another app is already using this shortcut."))
                        .accessibilityLabel(Text("Another app is already using this shortcut."))
                }
                Button {
                    if isRecording { ShortcutRecording.cancel() } else { ShortcutRecording.begin(action) }
                } label: {
                    Group {
                        if isRecording {
                            Text("Press shortcut…")
                        } else if let shortcut = settings.shortcuts[action] {
                            Text(verbatim: shortcut.displayText)
                        } else {
                            Text("None").foregroundStyle(.secondary)
                        }
                    }
                    .frame(minWidth: 96)
                }
            }
        }
    }
}

/// Listens for the key press that becomes an action's new shortcut. One
/// monitor for the app's lifetime; it lets every key through unless a
/// recording is under way.
@MainActor
enum ShortcutRecording {
    private static var monitor: Any?

    static func begin(_ action: HotKeyAction) {
        AppSettings.shared.recordingShortcut = action
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }

    static func cancel() {
        if AppSettings.shared.recordingShortcut != nil {
            AppSettings.shared.recordingShortcut = nil
        }
    }

    /// Returns whether the key press was consumed.
    private static func handle(_ event: NSEvent) -> Bool {
        let settings = AppSettings.shared
        guard let action = settings.recordingShortcut else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty, event.keyCode == 53 { // Esc
            cancel()
        } else if modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 { // Delete
            settings.shortcuts = Shortcut.assigning(nil, to: action, in: settings.shortcuts)
            cancel()
        } else if let shortcut = Shortcut(
            keyCode: event.keyCode,
            modifierFlags: modifiers,
            characters: event.charactersIgnoringModifiers
        ) {
            settings.shortcuts = Shortcut.assigning(shortcut, to: action, in: settings.shortcuts)
            cancel()
        } else {
            NSSound.beep()
        }
        return true
    }
}
