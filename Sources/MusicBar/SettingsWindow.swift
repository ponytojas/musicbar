import AppKit
import os
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    /// Text for the Copy Diagnostics button; set by whoever knows the state.
    var diagnostics: () -> String = { "" }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: .shared, diagnostics: diagnostics))
            let window = NSWindow(contentViewController: hosting)
            // The title comes from the pane on show. The sidebar runs the
            // window's full height, under the title bar.
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            // Lay out first: the toolbar SwiftUI adds changes the frame, and
            // restoring before that moved the window down on every open.
            window.layoutIfNeeded()
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

/// The panes of the settings window, in sidebar order.
enum SettingsPane: CaseIterable, Identifiable {
    case general, menuBar, equalizer, shortcuts, history

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .menuBar: "Menu Bar"
        case .equalizer: "Equalizer"
        case .shortcuts: "Shortcuts"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .menuBar: "menubar.rectangle"
        case .equalizer: "waveform"
        case .shortcuts: "keyboard"
        case .history: "clock"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .menuBar: .blue
        case .equalizer: .pink
        case .shortcuts: .indigo
        case .history: .orange
        }
    }
}

/// Laid out like System Settings: the panes in a sidebar, the chosen one
/// beside it.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    var diagnostics: () -> String = { "" }
    @State private var pane = SettingsPane.general
    @FocusState private var sidebarHasFocus: Bool

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(SettingsPane.allCases, selection: $pane) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    PaneIcon(pane: pane)
                }
            }
            // Wide enough for the Spanish names. The column width alone
            // leaves the sidebar at its narrower default.
            .frame(minWidth: 210)
            .navigationSplitViewColumnWidth(210)
            // Start in the sidebar, so the arrow keys move between panes.
            .focused($sidebarHasFocus)
            .onAppear { sidebarHasFocus = true }
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .navigationTitle(pane.title)
        }
        // Short enough for a 13-inch screen at its largest text size; each
        // pane scrolls if it ever needs more.
        .frame(width: 720, height: 500)
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .general: GeneralSettings(settings: settings, diagnostics: diagnostics)
        case .menuBar: MenuBarSettings(settings: settings)
        case .equalizer: EqualizerSettings(settings: settings)
        case .shortcuts: ShortcutSettings(settings: settings)
        case .history: HistorySettings(settings: settings, history: .shared)
        }
    }
}

/// A sidebar icon in the System Settings manner: a white symbol on a
/// coloured tile.
private struct PaneIcon: View {
    let pane: SettingsPane

    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityHidden(true)
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
    var diagnostics: () -> String = { "" }
    @State private var copiedDiagnostics = false
    @State private var confirmsReset = false
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

            Section {
                HStack {
                    Button(copiedDiagnostics ? "Copied" : "Copy Diagnostics") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnostics(), forType: .string)
                        copiedDiagnostics = true
                    }
                    Spacer()
                    Button("Reset All Settings…") { confirmsReset = true }
                }
            } header: {
                Text("Support")
            } footer: {
                Footnote("Diagnostics describe your setup for a bug report. They never include what you listen to.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmsReset) {
            Button("Reset", role: .destructive) {
                settings.resetToDefaults()
                // Also the way out of a wrong cover that got saved.
                if let covers = ArtworkCache.defaultDirectory {
                    Task.detached(priority: .utility) { ArtworkCache.clear(covers) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
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
    /// The template field is open, even if what's typed matches a preset.
    @State private var editsCustomFormat = false

    private static let customFormat = "custom"

    /// The picker's selection: a preset's template, or "custom".
    private var formatSelection: Binding<String> {
        Binding(
            get: {
                editsCustomFormat || !TitleFormat.presets.contains(settings.titleFormat)
                    ? Self.customFormat
                    : settings.titleFormat
            },
            set: { selection in
                editsCustomFormat = selection == Self.customFormat
                if selection != Self.customFormat { settings.titleFormat = selection }
            }
        )
    }

    /// A preset as the menu shows it: its template filled with the words
    /// themselves.
    private func presetName(_ template: String) -> String {
        TitleFormat.render(
            template,
            title: NSLocalizedString("Title", comment: ""),
            artist: NSLocalizedString("Artist", comment: ""),
            album: NSLocalizedString("Album", comment: "")
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show album artwork", isOn: $settings.showArtwork)
                Toggle("Show title", isOn: $settings.showTitle)
                Picker("Progress", selection: $settings.menuBarProgress) {
                    Text("None").tag(MenuBarProgressStyle.none)
                    Text("Line under the title").tag(MenuBarProgressStyle.line)
                    Text("Time remaining").tag(MenuBarProgressStyle.remaining)
                }
                Toggle("Hide when no player is open", isOn: $settings.hideWhenNoPlayer)
            } header: {
                Text("Show")
            } footer: {
                if settings.hideWhenNoPlayer {
                    Footnote("While it's hidden, open MusicBar again from Finder or Spotlight to get back to these settings.")
                }
            }

            Section {
                Picker("Text", selection: formatSelection) {
                    ForEach(TitleFormat.presets, id: \.self) { template in
                        Text(verbatim: presetName(template)).tag(template)
                    }
                    Divider()
                    Text("Custom").tag(Self.customFormat)
                }
                if formatSelection.wrappedValue == Self.customFormat {
                    TextField("Template", text: $settings.titleFormat)
                        .help(Text("Use {title}, {artist} and {album}."))
                }
                Picker("Text size", selection: $settings.titleFontSize) {
                    ForEach([10.0, 11, 12, 13, 14], id: \.self) { size in
                        Text("\(Int(size)) pt").tag(size)
                    }
                }
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
                if formatSelection.wrappedValue == Self.customFormat {
                    Footnote("Use {title}, {artist} and {album} in the template. Long titles scroll on their own while music plays, and whenever you hover the menu bar item.")
                } else {
                    Footnote("Long titles scroll on their own while music plays, and whenever you hover the menu bar item.")
                }
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

struct HistorySettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: ListeningHistory
    @State private var period = HistoryPeriod.week
    @State private var confirmsClear = false

    private var plays: [Play] {
        ListeningHistory.plays(history.plays, since: period.start(from: Date()))
    }

    var body: some View {
        let plays = plays
        Form {
            Section {
                Toggle("Keep listening history", isOn: $settings.keepListeningHistory)
                Picker("Period", selection: $period) {
                    Text("Last 7 days").tag(HistoryPeriod.week)
                    Text("Last 30 days").tag(HistoryPeriod.month)
                    Text("All time").tag(HistoryPeriod.all)
                }
                LabeledContent("Songs played") {
                    Text(verbatim: String(plays.count))
                }
            } footer: {
                Footnote("Kept only on this Mac. A song counts once it has played for 30 seconds.")
            }

            Section("Top Songs") {
                rows(ListeningHistory.topSongs(in: plays, limit: 10))
            }

            Section("Top Artists") {
                rows(ListeningHistory.topArtists(in: plays, limit: 5))
            }

            Section {
                Button("Clear History…") { confirmsClear = true }
                    .disabled(history.plays.isEmpty)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete the whole listening history?", isPresented: $confirmsClear) {
            Button("Delete", role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func rows(_ items: [PlayCount]) -> some View {
        if items.isEmpty {
            Text("Nothing yet").foregroundStyle(.secondary)
        } else {
            ForEach(items) { item in
                LabeledContent {
                    Text(verbatim: String(item.count)).monospacedDigit()
                } label: {
                    Text(verbatim: item.name).lineLimit(1)
                    if !item.detail.isEmpty {
                        Text(verbatim: item.detail).lineLimit(1)
                    }
                }
            }
        }
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
