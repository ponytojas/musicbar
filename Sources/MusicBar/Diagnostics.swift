import AppKit

/// A plain-text summary of the app's state for bug reports. It describes
/// the setup, never the listening: no titles, artists, or history.
struct Diagnostics {
    var version: String
    var build: String
    var system: String
    var architecture: String
    var language: String
    var installedPlayers: [PlayerApp]
    var runningPlayers: [PlayerApp]
    var activePlayer: PlayerApp
    var hasTrack: Bool
    var isPlaying: Bool
    var playersWithoutPermission: [PlayerApp]
    var equalizerShown: Bool
    var equalizerStyle: EqualizerStyle
    var captureFailed: Bool
    var playerMode: PlayerMode
    var unavailableShortcuts: [HotKeyAction]
    var notificationsEnabled: Bool

    var report: String {
        func names(_ players: [PlayerApp]) -> String {
            players.isEmpty ? "none" : players.map(\.scriptName).joined(separator: ", ")
        }
        let shortcuts = unavailableShortcuts.isEmpty
            ? "none"
            : unavailableShortcuts.map(\.rawValue).joined(separator: ", ")
        return """
        MusicBar \(version) (\(build))
        macOS \(system), \(architecture), language \(language)
        Players installed: \(names(installedPlayers))
        Players running: \(names(runningPlayers))
        Following: \(playerMode.rawValue), active \(activePlayer.scriptName)
        Track on display: \(hasTrack ? (isPlaying ? "yes, playing" : "yes, paused") : "no")
        Automation refused for: \(names(playersWithoutPermission))
        Equalizer: \(equalizerShown ? equalizerStyle.rawValue : "hidden")\(captureFailed ? ", audio capture failed" : "")
        Shortcuts refused by macOS: \(shortcuts)
        Song notifications: \(notificationsEnabled ? "on" : "off")
        """
    }

    static var architecture: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
