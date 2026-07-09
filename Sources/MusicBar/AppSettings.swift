import Foundation

/// User preferences, persisted in UserDefaults. Shared by the menu bar view
/// and the settings window.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var showArtwork: Bool {
        didSet { UserDefaults.standard.set(showArtwork, forKey: "showArtwork") }
    }
    @Published var showEqualizer: Bool {
        didSet { UserDefaults.standard.set(showEqualizer, forKey: "showEqualizer") }
    }
    @Published var showArtist: Bool {
        didSet { UserDefaults.standard.set(showArtist, forKey: "showArtist") }
    }
    @Published var textWidth: Double {
        didSet { UserDefaults.standard.set(textWidth, forKey: "textWidth") }
    }
    @Published var holdSeconds: Int {
        didSet { UserDefaults.standard.set(holdSeconds, forKey: "holdSeconds") }
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "showArtwork": true,
            "showEqualizer": true,
            "showArtist": true,
            "textWidth": 150.0,
            "holdSeconds": 10,
        ])
        showArtwork = defaults.bool(forKey: "showArtwork")
        showEqualizer = defaults.bool(forKey: "showEqualizer")
        showArtist = defaults.bool(forKey: "showArtist")
        textWidth = defaults.double(forKey: "textWidth")
        holdSeconds = defaults.integer(forKey: "holdSeconds")
    }
}
