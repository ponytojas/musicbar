import Foundation

/// What a `musicbar://` link asks for, so Raycast, Shortcuts, Stream Deck
/// or a shell script (`open musicbar://next`) can drive MusicBar.
///
/// Any app or web page can open such a link, so the commands are limited
/// to what the menu bar item itself does with a click, and every number
/// is range-checked.
enum URLCommand: Equatable {
    case playPause
    case next
    case previous
    case favorite
    case toggleCard
    case settings
    /// `musicbar://volume?level=40`
    case setVolume(Int)
    /// `musicbar://volume?by=-10`
    case changeVolume(Int)
    /// `musicbar://seek?by=30`, in seconds.
    case seek(Int)
    /// `musicbar://sleep?minutes=30`; 0 turns the timer off.
    case sleep(minutes: Int)

    static let scheme = "musicbar"

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let name = url.host?.lowercased() else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func number(_ name: String, in range: ClosedRange<Int>) -> Int? {
            query.first { $0.name == name }?.value.flatMap { Int($0) }.flatMap { range.contains($0) ? $0 : nil }
        }
        switch name {
        case "playpause": self = .playPause
        case "next": self = .next
        case "previous": self = .previous
        case "favorite": self = .favorite
        case "card": self = .toggleCard
        case "settings": self = .settings
        case "volume":
            if let level = number("level", in: 0...100) {
                self = .setVolume(level)
            } else if let step = number("by", in: -100...100) {
                self = .changeVolume(step)
            } else {
                return nil
            }
        case "seek":
            guard let seconds = number("by", in: -3_600...3_600) else { return nil }
            self = .seek(seconds)
        case "sleep":
            guard let minutes = number("minutes", in: 0...SleepTimer.maximumMinutes) else { return nil }
            self = .sleep(minutes: minutes)
        default:
            return nil
        }
    }
}
