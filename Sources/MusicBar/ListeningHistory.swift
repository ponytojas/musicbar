import Foundation
import os

/// One song that was listened to.
struct Play: Codable, Equatable {
    let title: String
    let artist: String
    let album: String
    /// Bundle identifier of the player.
    let player: String
    let date: Date
}

/// Adds up how long the song on display has actually been playing, so a
/// song skipped after a few seconds doesn't count as listened to.
struct PlayClock {
    private var accumulated: TimeInterval = 0
    private var playingSince: Date?

    mutating func setPlaying(_ playing: Bool, at now: Date) {
        if playing {
            if playingSince == nil { playingSince = now }
        } else if let since = playingSince {
            accumulated += now.timeIntervalSince(since)
            playingSince = nil
        }
    }

    func total(at now: Date) -> TimeInterval {
        accumulated + (playingSince.map { now.timeIntervalSince($0) } ?? 0)
    }
}

/// A row of a "most played" list.
struct PlayCount: Identifiable, Equatable {
    let name: String
    /// The artist, for a song; empty for an artist row.
    let detail: String
    let count: Int

    var id: String { name + "\u{1F}" + detail }
}

enum HistoryPeriod: String, CaseIterable {
    case week, month, all

    /// Plays on or after this date count; nil for everything.
    func start(from now: Date) -> Date? {
        switch self {
        case .week: now.addingTimeInterval(-7 * 24 * 60 * 60)
        case .month: now.addingTimeInterval(-30 * 24 * 60 * 60)
        case .all: nil
        }
    }
}

/// What has been listened to, kept in a file on this Mac and nowhere else.
/// One JSON object per line, so recording a song appends a line instead of
/// rewriting the file.
@MainActor
final class ListeningHistory: ObservableObject {
    static let shared = ListeningHistory(fileURL: defaultFileURL)

    @Published private(set) var plays: [Play]

    /// A song counts once it has played this long.
    static let minimumPlayTime: TimeInterval = 30
    /// Roughly a year and a half of steady listening; older plays go first.
    static let maximumPlays = 20_000

    private let fileURL: URL?

    private static var defaultFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MusicBar", isDirectory: true)
            .appendingPathComponent("history.jsonl")
    }

    /// `fileURL` nil keeps the history in memory only.
    init(fileURL: URL?, plays: [Play] = []) {
        self.fileURL = fileURL
        var loaded = plays
        if let fileURL, let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            let decoder = Self.decoder
            loaded += text.split(separator: "\n").compactMap { try? decoder.decode(Play.self, from: Data($0.utf8)) }
        }
        self.plays = loaded
        if loaded.count > Self.maximumPlays {
            self.plays = Array(loaded.suffix(Self.maximumPlays))
            rewriteFile()
        }
    }

    func record(_ play: Play) {
        plays.append(play)
        guard let fileURL, let line = try? Self.encoder.encode(play) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line + Data("\n".utf8))
        } catch {
            Logger.musicBar.error("Listening history not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    func clear() {
        plays = []
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func rewriteFile() {
        guard let fileURL else { return }
        let encoder = Self.encoder
        let lines = plays.compactMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        try? (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Statistics

    static func plays(_ plays: [Play], since start: Date?) -> [Play] {
        guard let start else { return plays }
        return plays.filter { $0.date >= start }
    }

    /// Most played songs, most played first; ties keep the more recently
    /// played one ahead.
    static func topSongs(in plays: [Play], limit: Int) -> [PlayCount] {
        ranked(plays, limit: limit) { PlayCount(name: $0.title, detail: $0.artist, count: 0) }
    }

    /// Most played artists. Songs without an artist are left out.
    static func topArtists(in plays: [Play], limit: Int) -> [PlayCount] {
        ranked(plays.filter { !$0.artist.isEmpty }, limit: limit) {
            PlayCount(name: $0.artist, detail: "", count: 0)
        }
    }

    private static func ranked(_ plays: [Play], limit: Int, row: (Play) -> PlayCount) -> [PlayCount] {
        var counts: [String: (row: PlayCount, count: Int, last: Date)] = [:]
        for play in plays {
            let entry = row(play)
            let existing = counts[entry.id]
            counts[entry.id] = (entry, (existing?.count ?? 0) + 1, max(existing?.last ?? play.date, play.date))
        }
        return counts.values
            .sorted { ($0.count, $0.last) > ($1.count, $1.last) }
            .prefix(limit)
            .map { PlayCount(name: $0.row.name, detail: $0.row.detail, count: $0.count) }
    }
}
