import AppKit

/// The Automation (Apple Events) permission MusicBar needs for each player.
/// TCC grants it per controlled application.
enum AutomationPermission {
    private static let explainedKey = "didExplainAutomation"
    private static let promptedPrefix = "didRequestAutomation."
    private static let errNotPermitted: OSStatus = -1743
    private static let errWouldRequireConsent: OSStatus = -1744

    /// Explains once, then requests each player the first time it is
    /// encountered. The system prompt blocks its caller until answered, so
    /// it is asked for off the main thread.
    @MainActor
    static func prepare(for players: [PlayerApp]) async {
        let defaults = UserDefaults.standard
        let unprompted = players.filter { !defaults.bool(forKey: promptedPrefix + $0.rawValue) }
        guard !unprompted.isEmpty else { return }

        let statuses = Dictionary(uniqueKeysWithValues: unprompted.map {
            ($0, status(for: $0.rawValue, askIfNeeded: false))
        })

        if statuses.values.contains(errWouldRequireConsent), !defaults.bool(forKey: explainedKey) {
            showExplainer()
            defaults.set(true, forKey: explainedKey)
        }

        var permissionDenied = false
        for player in unprompted {
            var result = statuses[player] ?? noErr
            if result == errWouldRequireConsent {
                let bundleID = player.rawValue
                result = await Task.detached { status(for: bundleID, askIfNeeded: true) }.value
            }
            permissionDenied = permissionDenied || result == errNotPermitted
            defaults.set(true, forKey: promptedPrefix + player.rawValue)
        }

        if permissionDenied {
            showDeniedAlert()
        }
    }

    @MainActor
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private nonisolated static func status(for bundleID: String, askIfNeeded: Bool) -> OSStatus {
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let aeDesc = descriptor.aeDesc else { return noErr }
        let wildcard = DescType(0x2A_2A_2A_2A) // '****'
        return AEDeterminePermissionToAutomateTarget(aeDesc, wildcard, wildcard, askIfNeeded)
    }

    @MainActor
    private static func showExplainer() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("MusicBar needs your permission", comment: "")
        alert.informativeText = NSLocalizedString(
            "MusicBar controls Music and Spotify with AppleScript to show the current track and toggle playback. macOS will now ask you to allow this.",
            comment: ""
        )
        alert.addButton(withTitle: NSLocalizedString("Continue", comment: ""))
        NSApp.activate()
        alert.runModal()
    }

    @MainActor
    private static func showDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Automation permission denied", comment: "")
        alert.informativeText = NSLocalizedString(
            "Without it MusicBar cannot read or control playback. Enable MusicBar under Automation in System Settings.",
            comment: ""
        )
        alert.addButton(withTitle: NSLocalizedString("Open System Settings", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: ""))
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            openSystemSettings()
        }
    }
}
