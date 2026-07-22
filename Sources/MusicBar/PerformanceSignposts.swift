import os.signpost

enum PerformanceSignposts {
    private static let log = OSLog(
        subsystem: "com.ponytojas.musicbar",
        category: .pointsOfInterest
    )

    static func begin(_ name: StaticString) -> OSSignpostID {
        let identifier = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: identifier)
        return identifier
    }

    static func end(_ name: StaticString, _ identifier: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: identifier)
    }
}
