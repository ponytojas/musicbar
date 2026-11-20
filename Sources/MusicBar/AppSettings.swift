import SwiftUI

enum EqualizerPosition: String, CaseIterable {
    case left, right
}

enum PlayerMode: String, CaseIterable {
    case automatic, appleMusic, spotify

    /// Players MusicBar reads and controls in this mode.
    var players: [PlayerApp] {
        switch self {
        case .automatic: PlayerApp.allCases
        case .appleMusic: [.appleMusic]
        case .spotify: [.spotify]
        }
    }
}

/// What the bars show.
enum EqualizerStyle: String, CaseIterable {
    /// Frequency bands of the player's audio, bass on the left.
    case spectrum
    /// Loudness of the player's audio over the last instant.
    case levels
    /// Decorative movement; never listens to audio, so it needs no
    /// System Audio Recording permission.
    case simulated

    var capturesAudio: Bool { self != .simulated }
}

enum EqualizerColorMode: String, CaseIterable {
    case gradient
    case fixed
    case random

    /// Preserve preferences written by versions that called these modes
    /// system/custom/rainbow.
    init(storedValue: String) {
        switch storedValue {
        case "system": self = .gradient
        case "custom": self = .fixed
        case "rainbow": self = .random
        default: self = Self(rawValue: storedValue) ?? .gradient
        }
    }
}

/// User preferences, persisted in UserDefaults. Shared by the menu bar view
/// and the settings window. Each property names its key and default once.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var playerMode: PlayerMode = AppSettings.storedEnum("playerMode", .automatic) {
        didSet { Self.save(playerMode.rawValue, "playerMode") }
    }
    @Published var showArtwork: Bool = AppSettings.stored("showArtwork", true) {
        didSet { Self.save(showArtwork, "showArtwork") }
    }
    @Published var showEqualizer: Bool = AppSettings.stored("showEqualizer", true) {
        didSet { Self.save(showEqualizer, "showEqualizer") }
    }
    /// Off leaves only the cover and equalizer in the menu bar.
    @Published var showTitle: Bool = AppSettings.stored("showTitle", true) {
        didSet { Self.save(showTitle, "showTitle") }
    }
    @Published var showArtist: Bool = AppSettings.stored("showArtist", true) {
        didSet { Self.save(showArtist, "showArtist") }
    }
    /// Short titles take only the room they need instead of `textWidth`.
    @Published var fitTitleToContent: Bool = AppSettings.stored("fitTitleToContent", true) {
        didSet { Self.save(fitTitleToContent, "fitTitleToContent") }
    }
    /// Removes the item from the menu bar while no allowed player is open.
    @Published var hideWhenNoPlayer: Bool = AppSettings.stored("hideWhenNoPlayer", false) {
        didSet { Self.save(hideWhenNoPlayer, "hideWhenNoPlayer") }
    }
    /// 0 keeps the title visible while paused.
    @Published var collapseAfterPauseMinutes: Int = AppSettings.stored("collapseAfterPauseMinutes", 0) {
        didSet { Self.save(collapseAfterPauseMinutes, "collapseAfterPauseMinutes") }
    }
    @Published var lookUpArtworkOnline: Bool = AppSettings.stored("lookUpArtworkOnline", true) {
        didSet { Self.save(lookUpArtworkOnline, "lookUpArtworkOnline") }
    }
    @Published var checkForUpdatesAutomatically: Bool = AppSettings.stored("checkForUpdatesAutomatically", false) {
        didSet { Self.save(checkForUpdatesAutomatically, "checkForUpdatesAutomatically") }
    }
    @Published var notifyOnTrackChange: Bool = AppSettings.stored("notifyOnTrackChange", false) {
        didSet { Self.save(notifyOnTrackChange, "notifyOnTrackChange") }
    }
    @Published var showHoverCard: Bool = AppSettings.stored("showHoverCard", true) {
        didSet { Self.save(showHoverCard, "showHoverCard") }
    }
    @Published var scrollChangesVolume: Bool = AppSettings.stored("scrollChangesVolume", true) {
        didSet { Self.save(scrollChangesVolume, "scrollChangesVolume") }
    }
    /// On makes a single click wait out the double-click interval.
    @Published var doubleClickOpensPlayer: Bool = AppSettings.stored("doubleClickOpensPlayer", false) {
        didSet { Self.save(doubleClickOpensPlayer, "doubleClickOpensPlayer") }
    }
    @Published var textWidth: Double = AppSettings.stored("textWidth", 150.0) {
        didSet { Self.save(textWidth, "textWidth") }
    }
    @Published var holdSeconds: Int = AppSettings.stored("holdSeconds", 10) {
        didSet { Self.save(holdSeconds, "holdSeconds") }
    }
    @Published var equalizerPosition: EqualizerPosition = AppSettings.storedEnum("equalizerPosition", .left) {
        didSet { Self.save(equalizerPosition.rawValue, "equalizerPosition") }
    }
    @Published var equalizerStyle: EqualizerStyle = AppSettings.storedEnum("equalizerStyle", .spectrum) {
        didSet { Self.save(equalizerStyle.rawValue, "equalizerStyle") }
    }
    /// Multiplies the bar heights: below 1 calms them, above 1 lifts quiet
    /// music.
    @Published var equalizerSensitivity: Double = AppSettings.stored("equalizerSensitivity", 1.0) {
        didSet { Self.save(equalizerSensitivity, "equalizerSensitivity") }
    }
    @Published var equalizerColorMode = EqualizerColorMode(
        storedValue: AppSettings.stored("equalizerColorMode", EqualizerColorMode.gradient.rawValue)
    ) {
        didSet { Self.save(equalizerColorMode.rawValue, "equalizerColorMode") }
    }
    @Published var equalizerColorHex: String = AppSettings.stored("equalizerColorHex", "#FF375F") {
        didSet { Self.save(equalizerColorHex, "equalizerColorHex") }
    }
    @Published var globalShortcuts: Bool = AppSettings.stored("globalShortcuts", true) {
        didSet { Self.save(globalShortcuts, "globalShortcuts") }
    }
    /// Actions without an entry have no shortcut.
    @Published var shortcuts: [HotKeyAction: Shortcut] = AppSettings.storedShortcuts() {
        didSet { Self.save(Shortcut.encode(shortcuts), "shortcuts") }
    }

    // Not persisted: state the settings window and the hot keys share.

    /// The action whose shortcut is being recorded. Hot keys are off
    /// meanwhile, or pressing a current shortcut would fire it instead.
    @Published var recordingShortcut: HotKeyAction?
    /// Shortcuts macOS refused to register, usually taken by another app.
    @Published var unavailableShortcuts: Set<HotKeyAction> = []

    var equalizerColor: Color {
        get { Color(hex: equalizerColorHex) }
        set { equalizerColorHex = newValue.hexString }
    }

    private init() {}

    private nonisolated static func stored<Value>(_ key: String, _ fallback: Value) -> Value {
        UserDefaults.standard.object(forKey: key) as? Value ?? fallback
    }

    private nonisolated static func storedEnum<Value: RawRepresentable>(
        _ key: String,
        _ fallback: Value
    ) -> Value where Value.RawValue == String {
        UserDefaults.standard.string(forKey: key).flatMap(Value.init(rawValue:)) ?? fallback
    }

    /// Nothing saved yet means the built-in defaults.
    private nonisolated static func storedShortcuts() -> [HotKeyAction: Shortcut] {
        UserDefaults.standard.data(forKey: "shortcuts").flatMap(Shortcut.decode) ?? HotKeyAction.defaultShortcuts
    }

    private nonisolated static func save(_ value: Any?, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hexString: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(
            format: "#%02X%02X%02X",
            Int(round(color.redComponent * 255)),
            Int(round(color.greenComponent * 255)),
            Int(round(color.blueComponent * 255))
        )
    }
}
