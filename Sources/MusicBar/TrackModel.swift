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

struct Playlist: Identifiable, Equatable {
    let id: String
    let name: String
}

@MainActor
final class TrackModel: ObservableObject {
    @Published var title: String = ""
    @Published var artist: String = ""
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
    /// Music's available AirPlay outputs; empty for Spotify.
    @Published var outputDevices: [OutputDevice] = []
    /// Short-lived feedback under the card's controls.
    @Published var popupNotice: String?
    @Published var isHovering: Bool = false
    @Published var screenActive: Bool = true
    /// Paused long enough that the menu bar shows only the music note.
    @Published var isCollapsed: Bool = false

    var hasTrack: Bool { !title.isEmpty }

    var displayText: String {
        artist.isEmpty ? title : "\(title) — \(artist)"
    }

    /// Assigns only what changed — @Published fires objectWillChange even for
    /// identical values, and the periodic reconcile usually re-reports the
    /// same state.
    func update(title: String, artist: String, isPlaying: Bool) {
        if self.title != title { self.title = title }
        if self.artist != artist { self.artist = artist }
        if self.isPlaying != isPlaying { self.isPlaying = isPlaying }
    }

    func clear() {
        update(title: "", artist: "", isPlaying: false)
        if artwork != nil { artwork = nil }
        if artworkLarge != nil { artworkLarge = nil }
        if progress != nil { progress = nil }
        if isFavorited != nil { isFavorited = nil }
    }
}
