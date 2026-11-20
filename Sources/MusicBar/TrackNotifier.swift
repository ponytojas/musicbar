import AppKit
import ImageIO
import os
import UniformTypeIdentifiers
import UserNotifications

/// Posts the "song changed" banner, with the cover and a button to skip.
@MainActor
final class TrackNotifier: NSObject, UNUserNotificationCenterDelegate {
    var onNextTrack: (() -> Void)?
    var onOpenPlayer: (() -> Void)?

    private static let category = "track-change"
    private static let nextAction = "next-track"

    /// UserNotifications needs a bundle; a bare `swift run` binary has none
    /// and would crash on first use.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func install() {
        guard Self.isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let next = UNNotificationAction(
            identifier: Self.nextAction,
            title: NSLocalizedString("Next Track", comment: "")
        )
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [next], intentIdentifiers: []),
        ])
    }

    /// Asks macOS for permission to show banners; false when refused.
    static func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func post(title: String, artist: String, album: String, artworkData: Data?) {
        guard Self.isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = [artist, album].filter { !$0.isEmpty }.joined(separator: " — ")
        content.categoryIdentifier = Self.category
        if let artworkData, let attachment = Self.attachment(from: artworkData) {
            content.attachments = [attachment]
        }
        // One identifier, so each song replaces the previous banner.
        let request = UNNotificationRequest(identifier: "track-change", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// Attachments must be files; the system moves this one into its own
    /// store, so nothing is left behind in the temporary folder.
    private static func attachment(from data: Data) -> UNNotificationAttachment? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              let fileExtension = UTType(typeIdentifier)?.preferredFilenameExtension
        else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("musicbar-cover-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        do {
            try data.write(to: url)
            return try UNNotificationAttachment(identifier: "cover", url: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show the banner even while MusicBar's settings window is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        Task { @MainActor in
            switch action {
            case Self.nextAction: self.onNextTrack?()
            case UNNotificationDefaultActionIdentifier: self.onOpenPlayer?()
            default: break
            }
        }
        completionHandler()
    }
}
