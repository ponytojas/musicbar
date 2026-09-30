import AppKit
import ImageIO
import os

enum PlayerApp: String, CaseIterable, Sendable {
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

/// Executes AppleScript off the main thread. NSAppleScript and its result
/// descriptors aren't Sendable, so the serial queue keeps every script object
/// on one thread for its lifetime and converts results to value types before
/// returning. This prevents slow player replies from beachballing the menu bar.
private struct ScriptResponse<Value: Sendable>: Sendable {
    let value: Value?
    let errorNumber: Int?
}

private final class ScriptRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MusicBar.applescript", qos: .userInitiated)
    /// Compiled scripts, keyed by source; the app uses a handful of fixed
    /// scripts, so caching avoids recompiling on every poll/notification.
    /// Accessed only on `queue`.
    private var compiledScripts: [String: NSAppleScript] = [:]

    func runString(_ source: String) async -> ScriptResponse<String> {
        await withCheckedContinuation { continuation in
            queue.async {
                let result = self.runSync(source)
                continuation.resume(returning: ScriptResponse(
                    value: result.descriptor?.stringValue,
                    errorNumber: result.errorNumber
                ))
            }
        }
    }

    func runData(_ source: String) async -> ScriptResponse<Data> {
        await withCheckedContinuation { continuation in
            queue.async {
                let result = self.runSync(source)
                let value: Data?
                if let text = result.descriptor?.stringValue, text.isEmpty {
                    value = nil
                } else {
                    value = result.descriptor?.data
                }
                continuation.resume(returning: ScriptResponse(
                    value: value,
                    errorNumber: result.errorNumber
                ))
            }
        }
    }

    func runCommand(_ source: String) async -> ScriptResponse<Bool> {
        await withCheckedContinuation { continuation in
            queue.async {
                let result = self.runSync(source)
                continuation.resume(returning: ScriptResponse(
                    value: result.descriptor == nil ? nil : true,
                    errorNumber: result.errorNumber
                ))
            }
        }
    }

    /// The descriptor never leaves the serial queue. Only String, Data, Bool,
    /// and an error number cross the concurrency boundary.
    private func runSync(_ source: String) -> (descriptor: NSAppleEventDescriptor?, errorNumber: Int?) {
        let signpost = PerformanceSignposts.begin("AppleScript")
        defer { PerformanceSignposts.end("AppleScript", signpost) }
        var error: NSDictionary?
        let script: NSAppleScript
        if let cached = compiledScripts[source] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: source), fresh.compileAndReturnError(&error) else {
                Logger.musicBar.error("AppleScript compile error: \(String(describing: error))")
                return (nil, Self.errorNumber(in: error))
            }
            compiledScripts[source] = fresh
            script = fresh
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            Logger.musicBar.error("AppleScript error: \(error)")
        }
        return (result, Self.errorNumber(in: error))
    }

    private static func errorNumber(in error: NSDictionary?) -> Int? {
        (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue
    }
}

/// Talks to Music/Spotify via Apple Events. Requires the Automation
/// permission (macOS prompts on first use).
@MainActor
final class MusicController {
    /// Player that most recently reported activity; commands target it.
    var activePlayer: PlayerApp = .appleMusic

    private let scriptRunner = ScriptRunner()
    private var permissionDeniedPlayers: Set<PlayerApp> = []

    private static let notPermittedError = -1743
    private static let maximumArtworkBytes = 20 * 1_024 * 1_024
    private static let maximumSearchResponseBytes = 1 * 1_024 * 1_024

    struct NowPlaying: Equatable {
        let title: String
        let artist: String
        let isPlaying: Bool
    }

    struct Candidate {
        let player: PlayerApp
        let nowPlaying: NowPlaying
    }

    func playPause() {
        guard activePlayer.isRunning else {
            openPlayerApp()
            return
        }
        send("playpause")
    }

    func nextTrack() { send("next track") }

    func previousTrack() { send("previous track") }

    /// Both players clamp `sound volume` to 0...100 themselves.
    func changeVolume(by delta: Int) { send("set sound volume to (sound volume + \(delta))") }

    /// Sends a one-line command to the active player if it's running.
    private func send(_ command: String) {
        let player = activePlayer
        guard player.isRunning else { return }
        permissionDeniedPlayers.remove(player)
        let source = "tell application \"\(player.scriptName)\" to \(command)"
        Task {
            let response = await scriptRunner.runCommand(source)
            recordPermissionFailure(response.errorNumber, for: player)
        }
    }

    /// Whether Apple Music's current track is a favorite; nil for Spotify,
    /// which has no scripting support for it. Newer Music calls the property
    /// `favorited`, older builds `loved`.
    func fetchFavorited() async -> Bool? {
        guard activePlayer == .appleMusic,
              PlayerApp.appleMusic.isRunning,
              !permissionDeniedPlayers.contains(.appleMusic)
        else { return nil }
        let source = """
        tell application "Music"
            if player state is stopped then return ""
            try
                return favorited of current track as text
            on error
                try
                    return loved of current track as text
                on error
                    return ""
                end try
            end try
        end tell
        """
        let response = await scriptRunner.runString(source)
        recordPermissionFailure(response.errorNumber, for: .appleMusic)
        switch response.value {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// Returns whether Music accepted the change.
    func setFavorited(_ favorited: Bool) async -> Bool {
        guard activePlayer == .appleMusic, PlayerApp.appleMusic.isRunning else { return false }
        let source = """
        tell application "Music"
            try
                set favorited of current track to \(favorited)
            on error
                set loved of current track to \(favorited)
            end try
        end tell
        """
        let response = await scriptRunner.runCommand(source)
        recordPermissionFailure(response.errorNumber, for: .appleMusic)
        return response.errorNumber == nil
    }

    /// Regular (non-smart, non-folder) Apple Music playlists; empty for
    /// Spotify, whose scripting can't reach playlists.
    func fetchPlaylists() async -> [Playlist] {
        guard activePlayer == .appleMusic,
              PlayerApp.appleMusic.isRunning,
              !permissionDeniedPlayers.contains(.appleMusic)
        else { return [] }
        let source = """
        tell application "Music"
            set output to ""
            repeat with aPlaylist in (every user playlist whose smart is false and special kind is none)
                set output to output & (persistent ID of aPlaylist) & tab & (name of aPlaylist) & linefeed
            end repeat
            return output
        end tell
        """
        let response = await scriptRunner.runString(source)
        recordPermissionFailure(response.errorNumber, for: .appleMusic)
        return response.value.map(Self.parsePlaylists) ?? []
    }

    /// Parses "ID⇥name" lines. IDs must be hex because they are later
    /// interpolated into a script.
    static func parsePlaylists(_ text: String) -> [Playlist] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, isPersistentID(fields[0]) else { return nil }
            return Playlist(id: String(fields[0]), name: String(fields[1]))
        }
    }

    private static func isPersistentID(_ id: some StringProtocol) -> Bool {
        !id.isEmpty && id.allSatisfy(\.isHexDigit)
    }

    enum PlaylistAddResult { case added, notInLibrary, failed }

    /// A streamed catalog song is a URL track, which Music refuses to
    /// duplicate into a playlist, so this adds the song's library copy: same
    /// persistent ID, else same name, artist, and album, else same name and
    /// artist. With no copy it first adds the song to the library, as Music
    /// itself does when adding to a playlist.
    func addCurrentTrack(to playlist: Playlist) async -> PlaylistAddResult {
        guard activePlayer == .appleMusic,
              PlayerApp.appleMusic.isRunning,
              Self.isPersistentID(playlist.id)
        else { return .failed }
        let source = """
        tell application "Music"
            set targetPlaylist to first user playlist whose persistent ID is "\(playlist.id)"
            set sourceTrack to current track
            set trackID to persistent ID of sourceTrack
            set trackName to name of sourceTrack
            set trackArtist to artist of sourceTrack
            set trackAlbum to album of sourceTrack
            set matches to (every track of library playlist 1 whose persistent ID is trackID)
            if matches is {} then set matches to (every track of library playlist 1 whose name is trackName and artist is trackArtist and album is trackAlbum)
            if matches is {} then set matches to (every track of library playlist 1 whose name is trackName and artist is trackArtist)
            if matches is {} then
                try
                    duplicate sourceTrack to library playlist 1
                end try
                set matches to (every track of library playlist 1 whose name is trackName and artist is trackArtist)
            end if
            if matches is {} then return "notInLibrary"
            duplicate (item 1 of matches) to targetPlaylist
            return "added"
        end tell
        """
        let response = await scriptRunner.runString(source)
        recordPermissionFailure(response.errorNumber, for: .appleMusic)
        switch response.value {
        case "added": return .added
        case "notInLibrary": return .notInLibrary
        default: return .failed
        }
    }

    /// Web link to Spotify's current track; Music exposes no shareable URL.
    func spotifyTrackLink() async -> URL? {
        guard activePlayer == .spotify, PlayerApp.spotify.isRunning else { return nil }
        let response = await scriptRunner.runString("tell application \"Spotify\" to return spotify url of current track")
        recordPermissionFailure(response.errorNumber, for: .spotify)
        return response.value.flatMap(Self.spotifyWebURL(fromURI:))
    }

    /// "spotify:track:ID" → https://open.spotify.com/track/ID. Local files
    /// ("spotify:local:…") have no web page and return nil.
    static func spotifyWebURL(fromURI uri: String) -> URL? {
        let parts = uri.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify", parts[1] != "local" else { return nil }
        return URL(string: "https://open.spotify.com/\(parts[1])/\(parts[2])")
    }

    func openPlayerApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: activePlayer.rawValue) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Checks the active player first, then prefers whichever player is
    /// actually playing. Returns nil when neither has a track.
    func fetchNowPlaying() async -> NowPlaying? {
        let allowedPlayers = AppSettings.shared.playerMode.players
        if !allowedPlayers.contains(activePlayer), let first = allowedPlayers.first {
            activePlayer = first
        }
        let currentPlayer = activePlayer
        var candidates: [Candidate] = []

        if let current = await fetchNowPlaying(from: currentPlayer) {
            let candidate = Candidate(player: currentPlayer, nowPlaying: current)
            if current.isPlaying { return current }
            candidates.append(candidate)
        }

        for player in allowedPlayers where player != currentPlayer {
            if let nowPlaying = await fetchNowPlaying(from: player) {
                candidates.append(Candidate(player: player, nowPlaying: nowPlaying))
            }
        }

        guard let preferred = Self.preferredCandidate(from: candidates, activePlayer: currentPlayer) else {
            return nil
        }
        activePlayer = preferred.player
        return preferred.nowPlaying
    }

    static func preferredCandidate(from candidates: [Candidate], activePlayer: PlayerApp) -> Candidate? {
        candidates.first(where: { $0.nowPlaying.isPlaying })
            ?? candidates.first(where: { $0.player == activePlayer })
            ?? candidates.first
    }

    private func fetchNowPlaying(from player: PlayerApp) async -> NowPlaying? {
        guard player.isRunning, !permissionDeniedPlayers.contains(player) else { return nil }
        let source = """
        tell application "\(player.scriptName)"
            if player state is stopped then return ""
            return (name of current track) & linefeed & (artist of current track) & linefeed & (player state as text)
        end tell
        """
        let response = await scriptRunner.runString(source)
        recordPermissionFailure(response.errorNumber, for: player)
        guard let result = response.value, !result.isEmpty else { return nil }
        return Self.parseNowPlaying(result)
    }

    /// Parses "title⏎artist⏎state". Fields are read from the end so a title
    /// with a line break stays intact.
    static func parseNowPlaying(_ result: String) -> NowPlaying? {
        var parts = result.components(separatedBy: "\n")
        guard parts.count >= 3 else { return nil }
        let state = parts.removeLast()
        let artist = parts.removeLast()
        return NowPlaying(
            title: parts.joined(separator: "\n"),
            artist: artist,
            isPlaying: state.caseInsensitiveCompare("playing") == .orderedSame
        )
    }

    /// Position and duration of the current track. Values cross as integer
    /// milliseconds so the locale's decimal separator doesn't matter.
    func fetchProgress() async -> PlaybackProgress? {
        let player = activePlayer
        guard player.isRunning, !permissionDeniedPlayers.contains(player) else { return nil }
        // Music reports duration in seconds, Spotify in milliseconds.
        let durationMilliseconds = player == .spotify
            ? "duration of current track"
            : "(duration of current track) * 1000"
        let source = """
        tell application "\(player.scriptName)"
            if player state is stopped then return ""
            return ((player position * 1000) as integer as text) & linefeed & ((\(durationMilliseconds)) as integer as text)
        end tell
        """
        let response = await scriptRunner.runString(source)
        recordPermissionFailure(response.errorNumber, for: player)
        guard let parts = response.value?.components(separatedBy: "\n"),
              parts.count == 2,
              let positionMilliseconds = Double(parts[0]),
              let durationMilliseconds = Double(parts[1]),
              durationMilliseconds > 0
        else { return nil }
        let duration = durationMilliseconds / 1000
        let position = min(positionMilliseconds / 1000, duration)
        return PlaybackProgress(position: position, duration: duration, start: Date().addingTimeInterval(-position))
    }

    /// Current track's small cover plus encoded data for a lazy popup decode.
    struct Artwork {
        let thumbnail: NSImage
        /// Retained only for the active track and decoded at popup size lazily.
        let encodedData: Data
    }

    /// Cover art of the current track on the active player, nil when unavailable.
    func fetchArtwork(title: String, artist: String) async -> Artwork? {
        let signpost = PerformanceSignposts.begin("Artwork Pipeline")
        defer { PerformanceSignposts.end("Artwork Pipeline", signpost) }
        let player = activePlayer
        guard !permissionDeniedPlayers.contains(player) else { return nil }

        let data: Data?
        switch player {
        case .appleMusic:
            if let imageData = await fetchAppleMusicArtworkData() {
                data = imageData
                break
            }
            // Streaming tracks often expose artwork late or never; retry once,
            // then fall back to the iTunes Search API.
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return nil
            }
            guard !Task.isCancelled else { return nil }
            if let retryData = await fetchAppleMusicArtworkData() {
                data = retryData
            } else if AppSettings.shared.lookUpArtworkOnline {
                data = await fetchArtworkFromITunesSearch(title: title, artist: artist)
            } else {
                data = nil
            }
        case .spotify:
            data = await fetchSpotifyArtworkData()
        }

        guard !Task.isCancelled,
              let data,
              let thumbnail = await Self.decodeArtwork(from: data, maxPixelSize: 68)
        else { return nil }
        return Artwork(thumbnail: thumbnail, encodedData: data)
    }

    private func fetchArtworkFromITunesSearch(title: String, artist: String) async -> Data? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(title)"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = components.url,
              let data = await downloadData(from: url, maximumBytes: Self.maximumSearchResponseBytes),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let match = Self.searchResult(in: results, matchingArtist: artist),
              let artworkURLString = match["artworkUrl100"] as? String,
              let artworkURL = URL(string: artworkURLString.replacingOccurrences(of: "100x100", with: "600x600")),
              artworkURL.scheme == "https"
        else { return nil }
        return await downloadData(
            from: artworkURL,
            maximumBytes: Self.maximumArtworkBytes,
            requiredMIMEPrefix: "image/"
        )
    }

    /// First result by the same artist; either name may carry extra credits
    /// ("A & B", "A feat. C"), so containment in either direction counts.
    static func searchResult(in results: [[String: Any]], matchingArtist artist: String) -> [String: Any]? {
        guard !artist.isEmpty else { return results.first }
        return results.first { result in
            guard let name = result["artistName"] as? String else { return false }
            return name.localizedCaseInsensitiveContains(artist) || artist.localizedCaseInsensitiveContains(name)
        }
    }

    private func fetchAppleMusicArtworkData() async -> Data? {
        guard PlayerApp.appleMusic.isRunning,
              !permissionDeniedPlayers.contains(.appleMusic)
        else { return nil }
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
        let response = await scriptRunner.runData(source)
        recordPermissionFailure(response.errorNumber, for: .appleMusic)
        guard let data = response.value,
              !data.isEmpty,
              data.count <= Self.maximumArtworkBytes
        else { return nil }
        return data
    }

    /// Spotify exposes artwork as an https URL instead of raw data.
    private func fetchSpotifyArtworkData() async -> Data? {
        guard PlayerApp.spotify.isRunning,
              !permissionDeniedPlayers.contains(.spotify)
        else { return nil }
        let source = """
        tell application "Spotify"
            if player state is stopped then return ""
            return artwork url of current track
        end tell
        """
        let response = await scriptRunner.runString(source)
        recordPermissionFailure(response.errorNumber, for: .spotify)
        guard let urlString = response.value,
              let url = URL(string: urlString),
              url.scheme == "https"
        else { return nil }
        return await downloadData(
            from: url,
            maximumBytes: Self.maximumArtworkBytes,
            requiredMIMEPrefix: "image/"
        )
    }

    private func downloadData(
        from url: URL,
        maximumBytes: Int,
        requiredMIMEPrefix: String? = nil
    ) async -> Data? {
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        request.allowsExpensiveNetworkAccess = true

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  response.expectedContentLength <= Int64(maximumBytes),
                  data.count <= maximumBytes
            else { return nil }
            if let requiredMIMEPrefix,
               let mimeType = response.mimeType,
               !mimeType.hasPrefix(requiredMIMEPrefix) {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    /// Decoding forces image work, so it runs off the main actor and follows
    /// cancellation from the track or popup task that requested it.
    nonisolated static func decodeArtwork(from data: Data, maxPixelSize: CGFloat) async -> NSImage? {
        let decodeTask = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return nil as NSImage? }
            return thumbnail(from: data, maxPixelSize: maxPixelSize)
        }
        return await withTaskCancellationHandler {
            await decodeTask.value
        } onCancel: {
            decodeTask.cancel()
        }
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

    func clearPermissionFailures(for player: PlayerApp? = nil) {
        if let player {
            permissionDeniedPlayers.remove(player)
        } else {
            permissionDeniedPlayers.removeAll()
        }
    }

    private func recordPermissionFailure(_ errorNumber: Int?, for player: PlayerApp) {
        if errorNumber == Self.notPermittedError {
            permissionDeniedPlayers.insert(player)
        }
    }

}
