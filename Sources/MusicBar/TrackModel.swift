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

    func update(title: String, artist: String, isPlaying: Bool) {
        self.title = title
        self.artist = artist
        self.isPlaying = isPlaying
    }

    func clear() {
        title = ""
        artist = ""
        isPlaying = false
        artwork = nil
    }
}
