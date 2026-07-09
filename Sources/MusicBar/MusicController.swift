import AppKit

enum PlayerApp: String, CaseIterable {
    case appleMusic = "com.apple.Music"
    case spotify = "com.spotify.client"

    /// Name used in `tell application "…"` scripts.
    var scriptName: String {
        switch self {
        case .appleMusic: "Music"
        case .spotify: "Spotify"
        }
    }

    var playerInfoNotification: Notification.Name {
        switch self {
        case .appleMusic: Notification.Name("com.apple.Music.playerInfo")
        case .spotify: Notification.Name("com.spotify.client.PlayerStateChanged")
        }
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: rawValue).isEmpty
    }
}

/// Talks to Music/Spotify via Apple Events. Requires the Automation
/// permission (macOS prompts on first use).
@MainActor
final class MusicController {
    /// Player that most recently reported activity; commands target it.
    var activePlayer: PlayerApp = .appleMusic

    struct NowPlaying {
        let title: String
        let artist: String
        let isPlaying: Bool
    }

    func playPause() {
        guard activePlayer.isRunning else {
            openPlayerApp()
            return
        }
        runScript("tell application \"\(activePlayer.scriptName)\" to playpause")
    }

    func nextTrack() {
        guard activePlayer.isRunning else { return }
        runScript("tell application \"\(activePlayer.scriptName)\" to next track")
    }

    func openPlayerApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: activePlayer.rawValue) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Checks the active player first, then the other one; switches
    /// `activePlayer` to whichever has a track. nil when neither does.
    func fetchNowPlaying() -> NowPlaying? {
        var candidates = [activePlayer]
        candidates += PlayerApp.allCases.filter { $0 != activePlayer }
        for player in candidates {
            if let nowPlaying = fetchNowPlaying(from: player) {
                activePlayer = player
                return nowPlaying
            }
        }
        return nil
    }

    private func fetchNowPlaying(from player: PlayerApp) -> NowPlaying? {
        guard player.isRunning else { return nil }
        let source = """
        tell application "\(player.scriptName)"
            if player state is stopped then return ""
            return (name of current track) & linefeed & (artist of current track) & linefeed & (player state as text)
        end tell
        """
        guard let result = runScript(source)?.stringValue, !result.isEmpty else { return nil }
        let parts = result.components(separatedBy: "\n")
        guard parts.count >= 3 else { return nil }
        return NowPlaying(
            title: parts[0],
            artist: parts[1],
            isPlaying: parts[2].caseInsensitiveCompare("playing") == .orderedSame
        )
    }

    /// Cover art of the current track on the active player, nil when unavailable.
    func fetchArtwork(title: String, artist: String) async -> NSImage? {
        switch activePlayer {
        case .appleMusic:
            if let image = fetchAppleMusicArtwork() { return image }
            // Streaming tracks often expose artwork late or never; retry once,
            // then fall back to the iTunes Search API.
            try? await Task.sleep(for: .seconds(2))
            if let image = fetchAppleMusicArtwork() { return image }
            return await fetchArtworkFromITunesSearch(title: title, artist: artist)
        case .spotify:
            return await fetchSpotifyArtwork()
        }
    }

    private func fetchArtworkFromITunesSearch(title: String, artist: String) async -> NSImage? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(title)"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let artworkURLString = results.first?["artworkUrl100"] as? String,
              let artworkURL = URL(string: artworkURLString.replacingOccurrences(of: "100x100", with: "300x300")),
              let (imageData, _) = try? await URLSession.shared.data(from: artworkURL)
        else { return nil }
        return NSImage(data: imageData)
    }

    private func fetchAppleMusicArtwork() -> NSImage? {
        guard PlayerApp.appleMusic.isRunning else { return nil }
        let source = """
        tell application "Music"
            if player state is stopped then return ""
            try
                return data of artwork 1 of current track
            on error
                return ""
            end try
        end tell
        """
        guard let descriptor = runScript(source) else { return nil }
        if let text = descriptor.stringValue, text.isEmpty { return nil }
        return NSImage(data: descriptor.data)
    }

    /// Spotify exposes artwork as an https URL instead of raw data.
    private func fetchSpotifyArtwork() async -> NSImage? {
        guard PlayerApp.spotify.isRunning else { return nil }
        let source = """
        tell application "Spotify"
            if player state is stopped then return ""
            return artwork url of current track
        end tell
        """
        guard let urlString = runScript(source)?.stringValue,
              let url = URL(string: urlString),
              url.scheme == "https" || url.scheme == "http"
        else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }

    @discardableResult
    private func runScript(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            NSLog("AppleScript error: \(error)")
        }
        return result
    }
}
