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
/// and the settings window.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var playerMode: PlayerMode {
        didSet { UserDefaults.standard.set(playerMode.rawValue, forKey: "playerMode") }
    }
    @Published var showArtwork: Bool {
        didSet { UserDefaults.standard.set(showArtwork, forKey: "showArtwork") }
    }
    @Published var showEqualizer: Bool {
        didSet { UserDefaults.standard.set(showEqualizer, forKey: "showEqualizer") }
    }
    @Published var showArtist: Bool {
        didSet { UserDefaults.standard.set(showArtist, forKey: "showArtist") }
    }
    /// 0 keeps the title visible while paused.
    @Published var collapseAfterPauseMinutes: Int {
        didSet { UserDefaults.standard.set(collapseAfterPauseMinutes, forKey: "collapseAfterPauseMinutes") }
    }
    @Published var lookUpArtworkOnline: Bool {
        didSet { UserDefaults.standard.set(lookUpArtworkOnline, forKey: "lookUpArtworkOnline") }
    }
    @Published var globalShortcuts: Bool {
        didSet { UserDefaults.standard.set(globalShortcuts, forKey: "globalShortcuts") }
    }
    @Published var textWidth: Double {
        didSet { UserDefaults.standard.set(textWidth, forKey: "textWidth") }
    }
    @Published var holdSeconds: Int {
        didSet { UserDefaults.standard.set(holdSeconds, forKey: "holdSeconds") }
    }
    @Published var equalizerPosition: EqualizerPosition {
        didSet { UserDefaults.standard.set(equalizerPosition.rawValue, forKey: "equalizerPosition") }
    }
    @Published var equalizerColorMode: EqualizerColorMode {
        didSet { UserDefaults.standard.set(equalizerColorMode.rawValue, forKey: "equalizerColorMode") }
    }
    @Published var equalizerColorHex: String {
        didSet { UserDefaults.standard.set(equalizerColorHex, forKey: "equalizerColorHex") }
    }

    var equalizerColor: Color {
        get { Color(hex: equalizerColorHex) }
        set { equalizerColorHex = newValue.hexString }
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "playerMode": PlayerMode.automatic.rawValue,
            "showArtwork": true,
            "showEqualizer": true,
            "showArtist": true,
            "lookUpArtworkOnline": true,
            "globalShortcuts": true,
            "textWidth": 150.0,
            "holdSeconds": 10,
            "equalizerPosition": EqualizerPosition.left.rawValue,
            "equalizerColorMode": EqualizerColorMode.gradient.rawValue,
            "equalizerColorHex": "#FF375F",
        ])
        playerMode = PlayerMode(rawValue: defaults.string(forKey: "playerMode") ?? "") ?? .automatic
        showArtwork = defaults.bool(forKey: "showArtwork")
        showEqualizer = defaults.bool(forKey: "showEqualizer")
        showArtist = defaults.bool(forKey: "showArtist")
        collapseAfterPauseMinutes = defaults.integer(forKey: "collapseAfterPauseMinutes")
        lookUpArtworkOnline = defaults.bool(forKey: "lookUpArtworkOnline")
        globalShortcuts = defaults.bool(forKey: "globalShortcuts")
        textWidth = defaults.double(forKey: "textWidth")
        holdSeconds = defaults.integer(forKey: "holdSeconds")
        equalizerPosition = EqualizerPosition(rawValue: defaults.string(forKey: "equalizerPosition") ?? "") ?? .left
        equalizerColorMode = EqualizerColorMode(
            storedValue: defaults.string(forKey: "equalizerColorMode") ?? ""
        )
        equalizerColorHex = defaults.string(forKey: "equalizerColorHex") ?? "#FF375F"
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
