import AppKit

@MainActor
final class TrackModel: ObservableObject {
    @Published var title: String = ""
    @Published var artist: String = ""
    @Published var isPlaying: Bool = false
    @Published var artwork: NSImage?
    @Published var isHovering: Bool = false
    @Published var screenActive: Bool = true

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
    }
}
