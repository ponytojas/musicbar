import Foundation

/// Pauses playback after a while, or when the current song ends. A timed
/// countdown is saved, so quitting and reopening MusicBar keeps it.
@MainActor
final class SleepTimer {
    enum Mode: Equatable {
        case off
        case minutes(Int)
        case endOfTrack
    }

    private(set) var mode: Mode = .off
    /// When a timed countdown pauses playback.
    private(set) var end: Date?

    var isActive: Bool { mode != .off }

    private var task: Task<Void, Never>?
    private let defaults: UserDefaults
    private let onFire: () -> Void
    private let onChange: () -> Void

    private static let endKey = "sleepTimerEnd"
    private static let minutesKey = "sleepTimerMinutes"

    /// `onFire` pauses playback; `onChange` runs whenever `isActive` may
    /// have changed.
    init(defaults: UserDefaults = .standard, onFire: @escaping () -> Void, onChange: @escaping () -> Void) {
        self.defaults = defaults
        self.onFire = onFire
        self.onChange = onChange
        let saved = defaults.object(forKey: Self.endKey) as? Date
        if let end = Self.pendingEnd(saved, now: Date()) {
            schedule(until: end, minutes: defaults.integer(forKey: Self.minutesKey))
        } else {
            defaults.removeObject(forKey: Self.endKey)
        }
    }

    /// A saved deadline still worth honoring: one that hasn't passed.
    static func pendingEnd(_ saved: Date?, now: Date) -> Date? {
        guard let saved, saved > now else { return nil }
        return saved
    }

    func set(_ mode: Mode) {
        cancel()
        switch mode {
        case .off:
            break
        case let .minutes(minutes):
            guard minutes > 0 else { break }
            schedule(until: Date().addingTimeInterval(TimeInterval(minutes * 60)), minutes: minutes)
        case .endOfTrack:
            // Not saved: after a relaunch "this song" is anyone's guess.
            self.mode = .endOfTrack
        }
        onChange()
    }

    /// Call when a different song starts.
    func trackDidChange() {
        guard mode == .endOfTrack else { return }
        fire()
    }

    private func schedule(until end: Date, minutes: Int) {
        mode = .minutes(minutes)
        self.end = end
        defaults.set(end, forKey: Self.endKey)
        defaults.set(minutes, forKey: Self.minutesKey)
        task = Task { @MainActor [weak self] in
            // The continuous clock keeps counting while the Mac sleeps.
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    private func fire() {
        cancel()
        onFire()
        onChange()
    }

    private func cancel() {
        task?.cancel()
        task = nil
        mode = .off
        end = nil
        defaults.removeObject(forKey: Self.endKey)
        defaults.removeObject(forKey: Self.minutesKey)
    }
}
