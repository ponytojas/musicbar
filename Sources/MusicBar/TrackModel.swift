import AppKit

/// Playback position for the hover popup. `start` is when the track would
/// have begun at normal speed, so SwiftUI can run the clock itself.
struct PlaybackProgress: Equatable {
    let position: TimeInterval
    let duration: TimeInterval
    let start: Date
    var end: Date { start.addingTimeInterval(duration) }
}

enum RepeatMode: String {
    case off, all, one
}

struct PlaybackModes: Equatable {
    var shuffle: Bool
    var repeatMode: RepeatMode
}

struct OutputDevice: Identifiable, Equatable {
    let id: String
    let name: String
    var isSelected: Bool
}

struct RecentTrack: Codable, Equatable {
    let title: String
    let artist: String
    /// Bundle identifier of the player it was heard on; nil in histories
    /// saved before songs could be replayed.
    var player: String?
    /// Music persistent ID or Spotify URI, when the player reported one.
    var trackID: String?

    var displayText: String { artist.isEmpty ? title : "\(title) — \(artist)" }

    /// Same song, whichever player or ID it carries.
    func isSameSong(as other: RecentTrack) -> Bool {
        title == other.title && artist == other.artist
    }

    static let limit = 10

    /// Newest first, without duplicates, capped at `limit`.
    static func adding(_ track: RecentTrack, to history: [RecentTrack]) -> [RecentTrack] {
        Array(([track] + history.filter { !$0.isSameSong(as: track) }).prefix(limit))
    }
}

/// Which song is on display, for telling a new song from more news about
/// the same one.
struct TrackIdentity: Equatable {
    let player: PlayerApp
    let title: String
    let artist: String
    let album: String

    /// nil without a title: nothing is queued.
    init?(player: PlayerApp, title: String, artist: String, album: String) {
        guard !title.isEmpty else { return nil }
        self.player = player
        self.title = title
        self.artist = artist
        self.album = album
    }

    /// The album tells two versions of a song apart, so they don't share a
    /// cover or favorite state. A missing album matches any: the players'
    /// notifications and their scripts don't always both report one, and
    /// that must not look like a new song.
    func isSameSong(as other: TrackIdentity) -> Bool {
        player == other.player
            && title == other.title
            && artist == other.artist
            && (album == other.album || album.isEmpty || other.album.isEmpty)
    }

    /// Stable text for comparing across suspension points.
    var key: String { [player.rawValue, title, artist, album].joined(separator: "|") }
}

struct Playlist: Identifiable, Equatable {
    let id: String
    let name: String
}

@MainActor
final class TrackModel: ObservableObject {
    @Published var title: String = ""
    @Published var artist: String = ""
    @Published var album: String = ""
    @Published var isPlaying: Bool = false
    @Published var artwork: NSImage?
    /// Popup-sized decode of the same cover; `artwork` stays menu-bar small.
    @Published var artworkLarge: NSImage?
    /// Fetched when the hover popup opens; nil otherwise.
    @Published var progress: PlaybackProgress?
    /// Apple Music favorite state; nil when unknown or unsupported (Spotify).
    @Published var isFavorited: Bool?
    /// Apple Music playlists the card can add to; empty for Spotify.
    @Published var playlists: [Playlist] = []
    /// Shuffle and repeat of the active player; nil until fetched.
    @Published var playbackModes: PlaybackModes?
    /// The active player's own volume, 0...100; nil until fetched.
    @Published var volume: Int?
    /// Music's available AirPlay outputs; empty for Spotify.
    @Published var outputDevices: [OutputDevice] = []
    /// Short-lived feedback under the card's controls.
    @Published var popupNotice: String?
    @Published var isHovering: Bool = false
    @Published var screenActive: Bool = true
    /// Paused long enough that the menu bar shows only the music note.
    @Published var isCollapsed: Bool = false
    /// A sleep timer is counting down; the menu bar shows a small moon.
    @Published var sleepTimerActive: Bool = false

    var hasTrack: Bool { !title.isEmpty }

    var displayText: String {
        artist.isEmpty ? title : "\(title) — \(artist)"
    }

    /// Second line of the card: artist and album, whichever exist.
    var artistAndAlbum: String {
        [artist, album].filter { !$0.isEmpty }.joined(separator: " — ")
    }

    /// Assigns only what changed — @Published fires objectWillChange even for
    /// identical values, and the periodic reconcile usually re-reports the
    /// same state.
    func update(title: String, artist: String, album: String, isPlaying: Bool) {
        if self.title != title { self.title = title }
        if self.artist != artist { self.artist = artist }
        if self.album != album { self.album = album }
        if self.isPlaying != isPlaying { self.isPlaying = isPlaying }
    }

    func clear() {
        update(title: "", artist: "", album: "", isPlaying: false)
        if artwork != nil { artwork = nil }
        if artworkLarge != nil { artworkLarge = nil }
        if progress != nil { progress = nil }
        if isFavorited != nil { isFavorited = nil }
    }
}
