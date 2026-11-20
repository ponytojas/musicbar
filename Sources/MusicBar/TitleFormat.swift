import Foundation

/// What the menu bar text says, as a template with `{title}`, `{artist}`
/// and `{album}` placeholders.
enum TitleFormat {
    static let titleAndArtist = "{title} — {artist}"
    static let titleOnly = "{title}"

    /// The ready-made choices in Settings, in menu order.
    static let presets = [
        titleAndArtist,
        "{artist} — {title}",
        titleOnly,
        "{title} — {artist} — {album}",
    ]

    /// Fills in the template. A value that is missing (a song without an
    /// artist, say) takes the separator before it along, so "Song — "
    /// never shows; first in line, it takes the separator after it. If
    /// nothing is left, the title stands in.
    static func render(_ template: String, title: String, artist: String, album: String) -> String {
        enum Part {
            case text(String)
            case value(String)
        }
        let values = ["{title}": title, "{artist}": artist, "{album}": album]

        var parts: [Part] = []
        var rest = Substring(template)
        while let range = values.keys.compactMap({ rest.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            if range.lowerBound > rest.startIndex {
                parts.append(.text(String(rest[..<range.lowerBound])))
            }
            parts.append(.value(values[String(rest[range])] ?? ""))
            rest = rest[range.upperBound...]
        }
        if !rest.isEmpty { parts.append(.text(String(rest))) }

        var keep = Array(repeating: true, count: parts.count)
        for index in parts.indices {
            guard case let .value(value) = parts[index], value.isEmpty else { continue }
            keep[index] = false
            if index > 0, keep[index - 1], case .text = parts[index - 1] {
                keep[index - 1] = false
            } else if index + 1 < parts.count, case .text = parts[index + 1] {
                keep[index + 1] = false
            }
        }

        let rendered = zip(parts, keep).compactMap { part, kept -> String? in
            guard kept else { return nil }
            switch part {
            case let .text(text), let .value(text): return text
            }
        }
        .joined()
        .trimmingCharacters(in: .whitespaces)
        return rendered.isEmpty ? title : rendered
    }
}
