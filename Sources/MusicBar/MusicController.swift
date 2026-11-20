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

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue) != nil
    }
}

/// Executes AppleScript off the main thread, so a slow player reply never
/// beachballs the menu bar. NSAppleScript and its result descriptors aren't
/// Sendable and aren't meant to hop threads, so every script object lives on
/// one dedicated thread and results are converted to value types before
/// they leave it. Scripts run one at a time, in order.
private struct ScriptResponse<Value: Sendable>: Sendable {
    let value: Value?
    let errorNumber: Int?
}

/// A single long-lived thread draining a job list. A serial dispatch queue
/// only promises one job at a time, not the same thread every time.
private final class SerialThread: @unchecked Sendable {
    private let condition = NSCondition()
    private var jobs: [@Sendable () -> Void] = []

    init(name: String) {
        let thread = Thread { [self] in run() }
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func enqueue(_ job: @escaping @Sendable () -> Void) {
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    /// App-lifetime thread, so this never returns.
    private func run() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            condition.unlock()
            autoreleasepool { job() }
        }
    }
}

private final class ScriptRunner: @unchecked Sendable {
    private let thread = SerialThread(name: "MusicBar.applescript")
    /// Compiled scripts, keyed by source. Most scripts are fixed, so caching
    /// avoids recompiling on every poll/notification; the few that embed a
    /// number (seek position, volume) would grow it forever, so it is
    /// emptied when it fills. Accessed only on `thread`.
    private var compiledScripts: [String: NSAppleScript] = [:]
    private static let maximumCachedScripts = 64

    func runString(_ source: String) async -> ScriptResponse<String> {
        await withCheckedContinuation { continuation in
            thread.enqueue {
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
            thread.enqueue {
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
            thread.enqueue {
                let result = self.runSync(source)
                continuation.resume(returning: ScriptResponse(
                    value: result.descriptor == nil ? nil : true,
                    errorNumber: result.errorNumber
                ))
            }
        }
    }

    /// The descriptor never leaves the script thread. Only String, Data,
    /// Bool, and an error number cross the concurrency boundary.
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
            if compiledScripts.count >= Self.maximumCachedScripts { compiledScripts.removeAll() }
            compiledScripts[source] = fresh
            script = fresh
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = Self.errorNumber(in: error) ?? 0
            Logger.musicBar.error("AppleScript error \(number, privacy: .public): \(error)")
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
    /// Remembered across launches so a Spotify listener's first click
    /// doesn't open Apple Music.
    var activePlayer: PlayerApp {
        didSet {
            guard activePlayer != oldValue else { return }
            UserDefaults.standard.set(activePlayer.rawValue, forKey: Self.lastPlayerKey)
        }
    }

    /// Players macOS refused to let MusicBar control. The menu offers a way
    /// to fix it while this isn't empty.
    private(set) var permissionDeniedPlayers: Set<PlayerApp> = [] {
        didSet { if permissionDeniedPlayers != oldValue { onPermissionChange?() } }
    }
    var onPermissionChange: (() -> Void)?

    private let scriptRunner = ScriptRunner()

    private static let notPermittedError = -1743
    private static let lastPlayerKey = "lastActivePlayer"

    init() {
        activePlayer = Self.initialPlayer(
            stored: UserDefaults.standard.string(forKey: Self.lastPlayerKey),
            allowed: AppSettings.shared.playerMode.players,
            installed: PlayerApp.allCases.filter(\.isInstalled)
        )
    }

    /// The player used last time if it's still allowed, else the first
    /// allowed player that is installed.
    static func initialPlayer(stored: String?, allowed: [PlayerApp], installed: [PlayerApp]) -> PlayerApp {
        if let stored, let player = PlayerApp(rawValue: stored), allowed.contains(player) {
            return player
        }
        return allowed.first(where: installed.contains) ?? allowed.first ?? .appleMusic
    }

    /// Wraps `body` in a `tell` that only reaches a running player — a bare
    /// `tell` relaunches one that quit a moment ago — and gives up after
    /// `timeout` seconds instead of AppleScript's two minutes, so a player
    /// stuck on a dialog can't hold up every later command.
    static func script(for player: PlayerApp, timeout: Int = 5, _ body: String) -> String {
        """
        if application "\(player.scriptName)" is not running then error number -600
        tell application "\(player.scriptName)"
            with timeout of \(timeout) seconds
                \(body)
            end timeout
        end tell
        """
    }

    struct NowPlaying: Equatable, Sendable {
        var title: String
        var artist: String
        var album: String = ""
        /// Music persistent ID or Spotify URI; nil when the player gave none.
        var trackID: String?
        var isPlaying: Bool
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

    func pause() { send("pause") }

    /// Pauses and, in the same script, puts the volume back where a fade
    /// found it: restoring first would blast the last second of the song.
    func pause(restoringVolume volume: Int?) async {
        let player = activePlayer
        guard player.isRunning else { return }
        let restore = volume.map { "\nset sound volume to \(min(100, max(0, $0)))" } ?? ""
        let response = await scriptRunner.runCommand(Self.script(for: player, "pause" + restore))
        recordPermissionFailure(response.errorNumber, for: player)
    }

    func seek(to position: TimeInterval) { send("set player position to \(position)") }

    /// Relative seek; both players clamp the result to the song.
    func seek(by seconds: Int) { send("set player position to (player position + (\(seconds)))") }

    /// Whether a player's notification should take over the menu bar. A
    /// paused or idle player must not displace the one that is playing.
    static func shouldAdopt(
        notificationFrom player: PlayerApp,
        isPlaying: Bool,
        activePlayer: PlayerApp,
        activeIsPlaying: Bool
    ) -> Bool {
        player == activePlayer || isPlaying || !activeIsPlaying
    }

    func fetchPlaybackModes() async -> PlaybackModes? {
        let player = activePlayer
        guard player.isRunning, !permissionDeniedPlayers.contains(player) else { return nil }
        let body = player == .appleMusic
            ? "return ((shuffle enabled) as text) & tab & ((song repeat) as text)"
            : "return ((shuffling) as text) & tab & ((repeating) as text)"
        let response = await scriptRunner.runString(Self.script(for: player, body))
        recordPermissionFailure(response.errorNumber, for: player)
        return response.value.flatMap(Self.parsePlaybackModes)
    }

    /// "shuffle⇥repeat". Music reports repeat as off/one/all, Spotify as a
    /// boolean.
    static func parsePlaybackModes(_ text: String) -> PlaybackModes? {
        let fields = text.split(separator: "\t").map(String.init)
        guard fields.count == 2 else { return nil }
        let repeatMode: RepeatMode = switch fields[1] {
        case "true", "all": .all
        case "one": .one
        default: .off
        }
        return PlaybackModes(shuffle: fields[0] == "true", repeatMode: repeatMode)
    }

    func setShuffle(_ enabled: Bool) {
        send(activePlayer == .appleMusic ? "set shuffle enabled to \(enabled)" : "set shuffling to \(enabled)")
    }

    /// Spotify only knows repeat on or off; `.one` counts as on there.
    func setRepeat(_ mode: RepeatMode) {
        send(activePlayer == .appleMusic ? "set song repeat to \(mode.rawValue)" : "set repeating to \(mode != .off)")
    }

    /// Returns the new volume. Both players clamp `sound volume` to 0...100.
    func changeVolume(by delta: Int) async -> Int? {
        let player = activePlayer
        guard player.isRunning else { return nil }
        let source = Self.script(for: player, """
        set sound volume to (sound volume + \(delta))
        return sound volume as text
        """)
        let response = await scriptRunner.runString(source)
        recordPermissionFailure(response.errorNumber, for: player)
        return response.value.flatMap { Int($0) }
    }

    func fetchVolume() async -> Int? {
        let player = activePlayer
        guard player.isRunning, !permissionDeniedPlayers.contains(player) else { return nil }
        let response = await scriptRunner.runString(Self.script(for: player, "return sound volume as text"))
        recordPermissionFailure(response.errorNumber, for: player)
        return response.value.flatMap { Int($0) }
    }

    func setVolume(_ volume: Int) async {
        let player = activePlayer
        guard player.isRunning else { return }
        let source = Self.script(for: player, "set sound volume to \(min(100, max(0, volume)))")
        let response = await scriptRunner.runCommand(source)
        recordPermissionFailure(response.errorNumber, for: player)
    }

    /// Sends a one-line command to the active player if it's running.
    private func send(_ command: String) {
        let player = activePlayer
        guard player.isRunning else { return }
        permissionDeniedPlayers.remove(player)
        let source = Self.script(for: player, command)
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
        let source = Self.script(for: .appleMusic, """
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
        """)
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
        let source = Self.script(for: .appleMusic, """
        try
            set favorited of current track to \(favorited)
        on error
            set loved of current track to \(favorited)
        end try
        """)
        let response = await scriptRunner.runCommand(source)
        recordPermissionFailure(response.errorNumber, for: .appleMusic)
        return response.errorNumber == nil
    }

    /// Stars and dislike of Apple Music's current track; nil for Spotify,
    /// which has neither in its scripting.
    func fetchRating() async -> TrackRating? {
        guard activePlayer == .appleMusic,
              PlayerApp.appleMusic.isRunning,
              !permissionDeniedPlayers.contains(.appleMusic)
        else { return nil }
        let source = Self.script(for: .appleMusic, """
        if player state is stopped then return ""
        set trackDisliked to ""
        try
            set trackDisliked to (disliked of current track) as text
        end try
        return ((rating of current track) as text) & tab & trackDisliked
        """)
        let response = await scriptRunner.runString(source)
        recordPermissionFailure(response.errorNumber, for: .appleMusic)
        return response.value.flatMap(Self.parseRating)
    }

    /// Parses "rating⇥disliked". Music counts 20 per star, so a half star
    /// rounds to the nearest whole one.
    static func parseRating(_ text: String) -> TrackRating? {
        let fields = text.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 2, let value = Int(fields[0]), (0...100).contains(value) else { return nil }
        let disliked: Bool? = switch fields[1] {
        case "true": true
        case "false": false
        default: nil
        }
        return TrackRating(stars: Int((Double(value) / 20).rounded()), isDisliked: disliked)
    }

    /// Returns whether Music accepted the rating; 0 stars removes it.
    func setRating(stars: Int) async -> Bool {
        guard activePlayer == .appleMusic, PlayerApp.appleMusic.isRunning else { return false }
        let value = min(5, max(0, stars)) * 20
        let response = await scriptRunner.runCommand(
            Self.script(for: .appleMusic, "set rating of current track to \(value)")
        )
        recordPermissionFailure(response.errorNumber, for: .appleMusic)
        return response.errorNumber == nil
    }

    func setDisliked(_ disliked: Bool) async -> Bool {
        guard activePlayer == .appleMusic, PlayerApp.appleMusic.isRunning else { return false }
        let response = await scriptRunner.runCommand(
            Self.script(for: .appleMusic, "set disliked of current track to \(disliked)")
        )
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
        let source = Self.script(for: .appleMusic, timeout: 15, """
        set output to ""
        repeat with aPlaylist in (every user playlist whose smart is false and special kind is none)
            set output to output & (persistent ID of aPlaylist) & tab & (name of aPlaylist) & linefeed
        end repeat
        return output
        """)
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

    nonisolated static func isPersistentID(_ id: some StringProtocol) -> Bool {
        !id.isEmpty && id.allSatisfy(\.isHexDigit)
    }

    /// "spotify:track:ID" or "spotify:episode:ID" with a plain ID, safe to
    /// put in a script.
    nonisolated static func isSpotifyURI(_ uri: some StringProtocol) -> Bool {
        let parts = uri.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 3
            && parts[0] == "spotify"
            && ["track", "episode"].contains(parts[1])
            && !parts[2].isEmpty
            && parts[2].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// Keeps an ID only in the shape its player uses; these end up inside
    /// scripts, so nothing else gets through.
    nonisolated static func validTrackID(_ id: String, for player: PlayerApp) -> String? {
        switch player {
        case .appleMusic: isPersistentID(id) ? id : nil
        case .spotify: isSpotifyURI(id) ? id : nil
        }
    }

    /// Track ID carried by a player's change notification. Music sends its
    /// persistent ID as a signed 64-bit number; scripts know it as hex.
    nonisolated static func trackID(fromNotification userInfo: [AnyHashable: Any], player: PlayerApp) -> String? {
        switch player {
        case .spotify:
            return (userInfo["Track ID"] as? String).flatMap { validTrackID($0, for: .spotify) }
        case .appleMusic:
            let value = userInfo["PersistentID"]
            let number = (value as? NSNumber)?.int64Value ?? (value as? String).flatMap { Int64($0) }
            guard let number, number != 0 else { return nil }
            return String(format: "%016llX", UInt64(bitPattern: number))
        }
    }

    enum PlaylistAddResult { case added, notInLibrary, failed }

    /// A streamed catalog song is a URL track, which Music refuses to
    /// duplicate into a playlist, so this adds the song's library copy: same
    /// persistent ID, else same name, artist, and album, else same name and
    /// artist. With no copy, the song is favorited just long enough for
    /// Music to put it in the library (scripting can't add it directly),
    /// then its favorite state is restored.
    func addCurrentTrack(to playlist: Playlist) async -> PlaylistAddResult {
        guard activePlayer == .appleMusic,
              PlayerApp.appleMusic.isRunning,
              Self.isPersistentID(playlist.id)
        else { return .failed }
        // One script on purpose: it keeps hold of the same track from the
        // lookup to the restore, even if playback moves on meanwhile.
        let source = Self.script(for: .appleMusic, timeout: 15, """
        set targetPlaylist to first user playlist whose persistent ID is "\(playlist.id)"
        set sourceTrack to current track
        set trackID to persistent ID of sourceTrack
        set trackName to name of sourceTrack
        set trackArtist to artist of sourceTrack
        set trackAlbum to album of sourceTrack
        set matches to (every track of library playlist 1 whose persistent ID is trackID)
        if matches is {} then set matches to (every track of library playlist 1 whose name is trackName and artist is trackArtist and album is trackAlbum)
        if matches is {} then set matches to (every track of library playlist 1 whose name is trackName and artist is trackArtist)
        set didFavorite to false
        if matches is {} then
            -- Favoriting is the only scripted way to put a streamed song
            -- in the library (with Music's add-favorites setting on).
            try
                if not (favorited of sourceTrack) then
                    set favorited of sourceTrack to true
                    set didFavorite to true
                end if
            on error
                try
                    if not (loved of sourceTrack) then
                        set loved of sourceTrack to true
                        set didFavorite to true
                    end if
                end try
            end try
            -- The library copy appears asynchronously.
            repeat 20 times
                set matches to (every track of library playlist 1 whose name is trackName and artist is trackArtist)
                if matches is not {} then exit repeat
                delay 0.25
            end repeat
        end if
        set addError to 0
        if matches is not {} then
            try
                duplicate (item 1 of matches) to targetPlaylist
            on error number errorNumber
                set addError to errorNumber
            end try
        end if
        -- Restore the favorite state even when the add failed.
        if didFavorite then
            try
                set favorited of sourceTrack to false
            on error
                try
                    set loved of sourceTrack to false
                end try
            end try
        end if
        if matches is {} then return "notInLibrary"
        if addError is not 0 then error number addError
        return "added"
        """)
        let response = await scriptRunner.runString(source)
        recordPermissionFailure(response.errorNumber, for: .appleMusic)
        switch response.value {
        case "added": return .added
        case "notInLibrary": return .notInLibrary
        default: return .failed
        }
    }

    /// Available AirPlay outputs in Music, this Mac included.
    func fetchOutputDevices() async -> [OutputDevice] {
        guard activePlayer == .appleMusic,
              PlayerApp.appleMusic.isRunning,
              !permissionDeniedPlayers.contains(.appleMusic)
        else { return [] }
        let source = Self.script(for: .appleMusic, """
        set output to ""
        repeat with airPlayDevice in (every AirPlay device whose available is true)
            set output to output & (persistent ID of airPlayDevice) & tab & ((selected of airPlayDevice) as text) & tab & (name of airPlayDevice) & linefeed
        end repeat
        return output
        """)
        let response = await scriptRunner.runString(source)
        recordPermissionFailure(response.errorNumber, for: .appleMusic)
        return response.value.map(Self.parseOutputDevices) ?? []
    }

    /// Parses "ID⇥selected⇥name" lines; IDs must be hex like playlist IDs.
    static func parseOutputDevices(_ text: String) -> [OutputDevice] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2)
            guard fields.count == 3, isPersistentID(fields[0]) else { return nil }
            return OutputDevice(id: String(fields[0]), name: String(fields[2]), isSelected: fields[1] == "true")
        }
    }

    /// Makes `device` Music's only output. Returns whether Music accepted it.
    func selectOutput(_ device: OutputDevice) async -> Bool {
        guard activePlayer == .appleMusic,
              PlayerApp.appleMusic.isRunning,
              Self.isPersistentID(device.id)
        else { return false }
        let source = Self.script(
            for: .appleMusic,
            "set current AirPlay devices to {(first AirPlay device whose persistent ID is \"\(device.id)\")}"
        )
        let response = await scriptRunner.runCommand(source)
        recordPermissionFailure(response.errorNumber, for: .appleMusic)
        return response.errorNumber == nil
    }

    /// Brings Music forward with the current track selected.
    func revealCurrentTrack() {
        guard activePlayer == .appleMusic, PlayerApp.appleMusic.isRunning else { return }
        let source = Self.script(for: .appleMusic, """
        reveal current track
        activate
        """)
        Task {
            let response = await scriptRunner.runCommand(source)
            recordPermissionFailure(response.errorNumber, for: .appleMusic)
        }
    }

    /// Web link to Spotify's current track; Music exposes no shareable URL.
    func spotifyTrackLink() async -> URL? {
        guard activePlayer == .spotify, PlayerApp.spotify.isRunning else { return nil }
        let response = await scriptRunner.runString(Self.script(for: .spotify, "return spotify url of current track"))
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

    /// Plays a song from the history again. Music can only replay songs in
    /// the library (scripts can't start a catalog song by ID); Spotify
    /// plays any URI. Returns false when the song couldn't be started.
    func play(_ track: RecentTrack) async -> Bool {
        guard let player = track.player.flatMap(PlayerApp.init(rawValue:)),
              let id = track.trackID.flatMap({ Self.validTrackID($0, for: player) }),
              player.isRunning,
              AppSettings.shared.playerMode.players.contains(player)
        else { return false }
        let body = switch player {
        case .appleMusic: "play (first track of library playlist 1 whose persistent ID is \"\(id)\")"
        case .spotify: "play track \"\(id)\""
        }
        let response = await scriptRunner.runCommand(Self.script(for: player, body))
        recordPermissionFailure(response.errorNumber, for: player)
        return response.errorNumber == nil
    }

    /// Starts one of Music's playlists from its first song (or a shuffled
    /// one, if shuffle is on).
    func play(_ playlist: Playlist) async -> Bool {
        guard PlayerApp.appleMusic.isRunning, Self.isPersistentID(playlist.id) else { return false }
        let source = Self.script(
            for: .appleMusic,
            "play (first user playlist whose persistent ID is \"\(playlist.id)\")"
        )
        let response = await scriptRunner.runCommand(source)
        recordPermissionFailure(response.errorNumber, for: .appleMusic)
        return response.errorNumber == nil
    }

    func openPlayerApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: activePlayer.rawValue) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Checks the active player first, then prefers whichever player is
    /// actually playing. Returns nil when neither has a track. The caller
    /// decides whether to make the winner the active player: a newer
    /// notification may have settled that while the scripts ran.
    func fetchNowPlaying() async -> Candidate? {
        let allowedPlayers = AppSettings.shared.playerMode.players
        if !allowedPlayers.contains(activePlayer), let first = allowedPlayers.first {
            activePlayer = first
        }
        let currentPlayer = activePlayer
        var candidates: [Candidate] = []

        if let current = await fetchNowPlaying(from: currentPlayer) {
            let candidate = Candidate(player: currentPlayer, nowPlaying: current)
            if current.isPlaying { return candidate }
            candidates.append(candidate)
        }

        for player in allowedPlayers where player != currentPlayer {
            if let nowPlaying = await fetchNowPlaying(from: player) {
                candidates.append(Candidate(player: player, nowPlaying: nowPlaying))
            }
        }

        return Self.preferredCandidate(from: candidates, activePlayer: currentPlayer)
    }

    static func preferredCandidate(from candidates: [Candidate], activePlayer: PlayerApp) -> Candidate? {
        candidates.first(where: { $0.nowPlaying.isPlaying })
            ?? candidates.first(where: { $0.player == activePlayer })
            ?? candidates.first
    }

    private func fetchNowPlaying(from player: PlayerApp) async -> NowPlaying? {
        guard player.isRunning, !permissionDeniedPlayers.contains(player) else { return nil }
        let trackID = player == .appleMusic ? "persistent ID of current track" : "spotify url of current track"
        // Title, artist and state are what the menu bar needs. The album
        // and ID are extras, so a track that lacks one still shows up.
        let source = Self.script(for: player, """
        if player state is stopped then return ""
        set trackAlbum to ""
        try
            set trackAlbum to album of current track
        end try
        set trackID to ""
        try
            set trackID to \(trackID)
        end try
        return (name of current track) & linefeed & (artist of current track) & linefeed & trackAlbum & linefeed & trackID & linefeed & (player state as text)
        """)
        let response = await scriptRunner.runString(source)
        recordPermissionFailure(response.errorNumber, for: player)
        guard let result = response.value, !result.isEmpty else { return nil }
        return Self.parseNowPlaying(result, from: player)
    }

    /// Parses "title⏎artist⏎album⏎id⏎state". Fields are read from the end so
    /// a title with a line break stays intact.
    static func parseNowPlaying(_ result: String, from player: PlayerApp) -> NowPlaying? {
        var parts = result.components(separatedBy: "\n")
        guard parts.count >= 5 else { return nil }
        let state = parts.removeLast()
        let trackID = parts.removeLast()
        let album = parts.removeLast()
        let artist = parts.removeLast()
        return NowPlaying(
            title: parts.joined(separator: "\n"),
            artist: artist,
            album: album,
            trackID: validTrackID(trackID, for: player),
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
        let source = Self.script(for: player, """
        if player state is stopped then return ""
        return ((player position * 1000) as integer as text) & linefeed & ((\(durationMilliseconds)) as integer as text)
        """)
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

    /// Songs Apple's iTunes Search returns for a title and artist.
    private func searchITunes(title: String, artist: String) async -> [[String: Any]] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(title)"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = components.url,
              let data = await ArtworkDownloader.data(
                  from: url,
                  maximumBytes: ArtworkDownloader.maximumSearchResponseBytes
              ),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]]
        else { return [] }
        return results
    }

    /// Web link to a song on Apple Music. Music's scripting has no link for
    /// the current track, so the song is looked up by title and artist;
    /// nil when the search has no confident match.
    func appleMusicTrackLink(title: String, artist: String) async -> URL? {
        let results = await searchITunes(title: title, artist: artist)
        guard let match = Self.searchResult(in: results, matchingArtist: artist, title: title),
              let link = match["trackViewUrl"] as? String
        else { return nil }
        return Self.appleMusicWebURL(from: link)
    }

    /// Only an https link to music.apple.com is worth putting on the
    /// clipboard.
    static func appleMusicWebURL(from link: String) -> URL? {
        guard let url = URL(string: link), url.scheme == "https", url.host == "music.apple.com" else { return nil }
        return url
    }

    private func fetchArtworkFromITunesSearch(title: String, artist: String) async -> Data? {
        let results = await searchITunes(title: title, artist: artist)
        guard let match = Self.searchResult(in: results, matchingArtist: artist),
              let artworkURLString = match["artworkUrl100"] as? String,
              let artworkURL = URL(string: artworkURLString.replacingOccurrences(of: "100x100", with: "600x600")),
              ArtworkDownloader.isTrustedArtworkURL(artworkURL)
        else { return nil }
        return await ArtworkDownloader.data(
            from: artworkURL,
            maximumBytes: ArtworkDownloader.maximumArtworkBytes,
            requiredMIMEPrefix: "image/"
        )
    }

    /// First result by the same artist; either name may carry extra credits
    /// ("A & B", "A feat. C"), so containment in either direction counts.
    /// With a `title`, the song has to match as well: a cover can come from
    /// a sibling track, a link has to be the song itself. An exact name
    /// wins over a version of it ("Song (Remastered)").
    static func searchResult(
        in results: [[String: Any]],
        matchingArtist artist: String,
        title: String? = nil
    ) -> [String: Any]? {
        let byArtist = results.filter { result in
            guard !artist.isEmpty else { return true }
            guard let name = result["artistName"] as? String else { return false }
            return name.localizedCaseInsensitiveContains(artist) || artist.localizedCaseInsensitiveContains(name)
        }
        guard let title else { return byArtist.first }
        func name(_ result: [String: Any]) -> String { (result["trackName"] as? String) ?? "" }
        return byArtist.first { name($0).caseInsensitiveCompare(title) == .orderedSame }
            ?? byArtist.first { isVersion(name($0), of: title) || isVersion(title, of: name($0)) }
    }

    /// "Song (Live)" and "Song - Single" are versions of "Song";
    /// "Songbird" and "Another Song" are not.
    static func isVersion(_ name: String, of title: String) -> Bool {
        let name = name.lowercased()
        let title = title.lowercased()
        guard !title.isEmpty, name.hasPrefix(title), name.count > title.count else { return false }
        let next = name[name.index(name.startIndex, offsetBy: title.count)]
        return !next.isLetter && !next.isNumber
    }

    private func fetchAppleMusicArtworkData() async -> Data? {
        guard PlayerApp.appleMusic.isRunning,
              !permissionDeniedPlayers.contains(.appleMusic)
        else { return nil }
        let source = Self.script(for: .appleMusic, timeout: 15, """
        if player state is stopped then return ""
        try
            return data of artwork 1 of current track
        on error
            return ""
        end try
        """)
        let response = await scriptRunner.runData(source)
        recordPermissionFailure(response.errorNumber, for: .appleMusic)
        guard let data = response.value,
              !data.isEmpty,
              data.count <= ArtworkDownloader.maximumArtworkBytes
        else { return nil }
        return data
    }

    /// Spotify exposes artwork as an https URL instead of raw data.
    private func fetchSpotifyArtworkData() async -> Data? {
        guard PlayerApp.spotify.isRunning,
              !permissionDeniedPlayers.contains(.spotify)
        else { return nil }
        let source = Self.script(for: .spotify, """
        if player state is stopped then return ""
        return artwork url of current track
        """)
        let response = await scriptRunner.runString(source)
        recordPermissionFailure(response.errorNumber, for: .spotify)
        guard let urlString = response.value,
              let url = URL(string: urlString),
              ArtworkDownloader.isTrustedArtworkURL(url)
        else { return nil }
        return await ArtworkDownloader.data(
            from: url,
            maximumBytes: ArtworkDownloader.maximumArtworkBytes,
            requiredMIMEPrefix: "image/"
        )
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
