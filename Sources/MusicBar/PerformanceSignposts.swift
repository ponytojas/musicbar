import os

extension Logger {
    static let musicBar = Logger(subsystem: "com.ponytojas.musicbar", category: "general")
}

enum PerformanceSignposts {
    private static let signposter = OSSignposter(
        subsystem: "com.ponytojas.musicbar",
        category: .pointsOfInterest
    )

    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}
