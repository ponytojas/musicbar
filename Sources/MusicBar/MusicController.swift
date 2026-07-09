import AppKit
import ImageIO

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

/// Executes AppleScript off the main thread. NSAppleScript is documented as
/// main-thread-only, but sending Apple Events is safe from any single thread;
/// the serial queue keeps every script object on one thread for its lifetime.
/// This keeps slow player replies (app launching, busy) from beachballing the
/// menu bar.
private final class ScriptRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MusicBar.applescript", qos: .userInitiated)
    /// Compiled scripts, keyed by source; the app uses a handful of fixed
    /// scripts, so caching avoids recompiling on every poll/notification.
    /// Accessed only on `queue`.
    private var compiledScripts: [String: NSAppleScript] = [:]

    func run(_ source: String) async -> NSAppleEventDescriptor? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.runSync(source))
            }
        }
    }

    private func runSync(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let script: NSAppleScript
        if let cached = compiledScripts[source] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: source), fresh.compileAndReturnError(&error) else {
                NSLog("AppleScript compile error: \(error ?? [:])")
                return nil
            }
            compiledScripts[source] = fresh
            script = fresh
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("AppleScript error: \(error)")
        }
        return result
    }
}

/// Talks to Music/Spotify via Apple Events. Requires the Automation
/// permission (macOS prompts on first use).
@MainActor
final class MusicController {
    /// Player that most recently reported activity; commands target it.
    var activePlayer: PlayerApp = .appleMusic

    private let scriptRunner = ScriptRunner()

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
        let source = "tell application \"\(activePlayer.scriptName)\" to playpause"
        Task { await scriptRunner.run(source) }
    }

    func nextTrack() {
        guard activePlayer.isRunning else { return }
        let source = "tell application \"\(activePlayer.scriptName)\" to next track"
        Task { await scriptRunner.run(source) }
    }

    func openPlayerApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: activePlayer.rawValue) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Checks the active player first, then the other one; switches
    /// `activePlayer` to whichever has a track. nil when neither does.
    func fetchNowPlaying() async -> NowPlaying? {
        var candidates = [activePlayer]
        candidates += PlayerApp.allCases.filter { $0 != activePlayer }
        for player in candidates {
            if let nowPlaying = await fetchNowPlaying(from: player) {
                activePlayer = player
                return nowPlaying
            }
        }
        return nil
    }

    private func fetchNowPlaying(from player: PlayerApp) async -> NowPlaying? {
        guard player.isRunning else { return nil }
        let source = """
        tell application "\(player.scriptName)"
            if player state is stopped then return ""
            return (name of current track) & linefeed & (artist of current track) & linefeed & (player state as text)
        end tell
        """
        guard let result = (await scriptRunner.run(source))?.stringValue, !result.isEmpty else { return nil }
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
            if let image = await fetchAppleMusicArtwork() { return image }
            // Streaming tracks often expose artwork late or never; retry once,
            // then fall back to the iTunes Search API.
            try? await Task.sleep(for: .seconds(2))
            if let image = await fetchAppleMusicArtwork() { return image }
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
        return await Self.decodeThumbnail(from: imageData)
    }

    private func fetchAppleMusicArtwork() async -> NSImage? {
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
        guard let descriptor = await scriptRunner.run(source) else { return nil }
        if let text = descriptor.stringValue, text.isEmpty { return nil }
        return await Self.decodeThumbnail(from: descriptor.data)
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
        guard let urlString = (await scriptRunner.run(source))?.stringValue,
              let url = URL(string: urlString),
              url.scheme == "https" || url.scheme == "http"
        else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return await Self.decodeThumbnail(from: data)
    }

    /// The menu bar shows covers at 17 pt; decode a small thumbnail instead of
    /// keeping the full-size image (Music can return multi-megapixel artwork).
    /// Decoding forces a full-image decode, so it runs off the main actor.
    private static func decodeThumbnail(from data: Data) async -> NSImage? {
        await Task.detached(priority: .utility) { thumbnail(from: data) }.value
    }

    private nonisolated static func thumbnail(from data: Data, maxPixelSize: CGFloat = 68) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }

}
