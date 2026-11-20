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
    private let onFade: (Double) -> Void

    private static let endKey = "sleepTimerEnd"
    private static let minutesKey = "sleepTimerMinutes"

    /// How long before a timed pause the volume starts to drop.
    static let fadeDuration: TimeInterval = 30
    /// The longest countdown the custom option accepts: twelve hours.
    nonisolated static let maximumMinutes = 720

    /// `onFire` pauses playback; `onChange` runs whenever `isActive` may
    /// have changed; `onFade` is called every couple of seconds through
    /// the last `fadeDuration` with how much volume should be left, from
    /// just under 1 down toward 0.
    init(
        defaults: UserDefaults = .standard,
        onFire: @escaping () -> Void,
        onChange: @escaping () -> Void,
        onFade: @escaping (Double) -> Void = { _ in }
    ) {
        self.defaults = defaults
        self.onFire = onFire
        self.onChange = onChange
        self.onFade = onFade
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

    /// Share of the volume left with `remaining` seconds to go.
    static func fadeFraction(remaining: TimeInterval) -> Double {
        min(1, max(0, remaining / fadeDuration))
    }

    /// The volume to set mid-fade, never above where it started.
    static func fadedVolume(base: Int, fraction: Double) -> Int {
        min(base, max(0, Int((Double(base) * fraction).rounded())))
    }

    /// Minutes typed into the custom field, if they make a usable timer.
    static func customMinutes(from text: String) -> Int? {
        guard let minutes = Int(text.trimmingCharacters(in: .whitespaces)),
              (1...maximumMinutes).contains(minutes)
        else { return nil }
        return minutes
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
            let untilFade = end.timeIntervalSinceNow - Self.fadeDuration
            try? await Task.sleep(for: .seconds(max(0, untilFade)))
            while !Task.isCancelled, end.timeIntervalSinceNow > 0 {
                self?.onFade(Self.fadeFraction(remaining: end.timeIntervalSinceNow))
                try? await Task.sleep(for: .seconds(min(2, max(0, end.timeIntervalSinceNow))))
            }
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
