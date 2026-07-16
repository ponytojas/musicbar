import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let music = MusicController()
    private let model = TrackModel()
    private let settingsWindow = SettingsWindowController()
    private lazy var hoverPopup = HoverPopupController(model: model)

    private var singleClickTimer: Timer?
    private var refreshTimer: Timer?
    private var lastArtworkKey: String?
    private var isRefreshing = false
    /// Post-command reconcile; cancelled when the player's own notification
    /// arrives first so we don't fetch the same state twice.
    private var pendingReconcile: Task<Void, Never>?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        observePlayerNotifications()
        observeScreenState()
        runFirstLaunchPermissionFlow()
        Task { await refresh() }

        // Fallback reconciliation in case a notification is missed. Skipped
        // while the screen is locked/asleep; the wake handler reconciles.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.model.screenActive else { return }
                await self.refresh()
            }
        }
        refreshTimer?.tolerance = 5
    }

    // MARK: - Setup

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let hosting = PassThroughHostingView(rootView: StatusBarView(model: model))
        hosting.onHoverChange = { [weak self] hovering in
            guard let self else { return }
            self.model.isHovering = hovering
            self.hoverPopup.setHovering(hovering, relativeTo: self.statusItem.button)
        }
        hosting.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: button.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
    }

    private func observePlayerNotifications() {
        // Both players post on every play/pause/track change. No polling.
        for player in PlayerApp.allCases {
            DistributedNotificationCenter.default().addObserver(
                forName: player.playerInfoNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let userInfo = note.userInfo
                Task { @MainActor in self?.handlePlayerInfo(userInfo, from: player) }
            }
        }
    }

    /// Freeze the equalizer while the screen is locked or asleep.
    private func observeScreenState() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(screenBecameInactive), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screenBecameActive), name: NSWorkspace.screensDidWakeNotification, object: nil)
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screenBecameInactive), name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(screenBecameActive), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    @objc nonisolated private func screenBecameInactive() {
        Task { @MainActor in self.model.screenActive = false }
    }

    @objc nonisolated private func screenBecameActive() {
        Task { @MainActor in
            self.model.screenActive = true
            // Catch up on anything missed while refreshes were paused.
            await self.refresh()
        }
    }

    // MARK: - Automation permission (first run)

    private static let automationExplainedKey = "didExplainAutomation"
    private static let errNotPermitted: OSStatus = -1743
    private static let errWouldRequireConsent: OSStatus = -1744

    private func runFirstLaunchPermissionFlow() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.automationExplainedKey) else { return }
        // Permission can only be checked against a running app; retry next launch.
        guard PlayerApp.appleMusic.isRunning else { return }
        defaults.set(true, forKey: Self.automationExplainedKey)

        switch automationPermission(for: PlayerApp.appleMusic.rawValue, askIfNeeded: false) {
        case Self.errWouldRequireConsent:
            showPermissionExplainer()
            if automationPermission(for: PlayerApp.appleMusic.rawValue, askIfNeeded: true) == Self.errNotPermitted {
                showPermissionDeniedAlert()
            }
        case Self.errNotPermitted:
            showPermissionDeniedAlert()
        default:
            break
        }
    }

    private func automationPermission(for bundleID: String, askIfNeeded: Bool) -> OSStatus {
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let aeDesc = descriptor.aeDesc else { return noErr }
        let wildcard = DescType(0x2A_2A_2A_2A) // '****'
        return AEDeterminePermissionToAutomateTarget(aeDesc, wildcard, wildcard, askIfNeeded)
    }

    private func showPermissionExplainer() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("MusicBar needs your permission", comment: "")
        alert.informativeText = NSLocalizedString(
            "MusicBar controls Music and Spotify with AppleScript to show the current track and toggle playback. macOS will now ask you to allow this.",
            comment: ""
        )
        alert.addButton(withTitle: NSLocalizedString("Continue", comment: ""))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showPermissionDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Automation permission denied", comment: "")
        alert.informativeText = NSLocalizedString(
            "Without it MusicBar cannot read or control playback. Enable MusicBar under Automation in System Settings.",
            comment: ""
        )
        alert.addButton(withTitle: NSLocalizedString("Open System Settings", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: ""))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - State

    private func handlePlayerInfo(_ userInfo: [AnyHashable: Any]?, from player: PlayerApp) {
        // The notification carries the fresh state; a pending post-command
        // reconcile would only re-fetch the same thing.
        pendingReconcile?.cancel()
        pendingReconcile = nil

        let state = (userInfo?["Player State"] as? String) ?? "Stopped"
        if state == "Stopped" {
            // Another player might still be active; re-scan.
            if player == music.activePlayer { Task { await refresh() } }
            return
        }
        music.activePlayer = player
        model.update(
            title: (userInfo?["Name"] as? String) ?? "",
            artist: (userInfo?["Artist"] as? String) ?? "",
            isPlaying: state == "Playing"
        )
        refreshArtworkIfNeeded()
        updateAccessibility()
    }

    private func refresh() async {
        // Coalesce: a refresh already in flight will land the same state.
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if let nowPlaying = await music.fetchNowPlaying() {
            model.update(title: nowPlaying.title, artist: nowPlaying.artist, isPlaying: nowPlaying.isPlaying)
            refreshArtworkIfNeeded()
        } else {
            model.clear()
            lastArtworkKey = nil
        }
        updateAccessibility()
    }

    /// Fetch cover art only when the track actually changed — playerInfo
    /// notifications also fire on plain play/pause.
    private func refreshArtworkIfNeeded() {
        let key = "\(music.activePlayer.rawValue)|\(model.title)|\(model.artist)"
        guard key != lastArtworkKey else { return }
        lastArtworkKey = key
        Task { @MainActor [weak self] in
            guard let self else { return }
            let artwork = await self.music.fetchArtwork(title: self.model.title, artist: self.model.artist)
            // The track may have changed while the artwork was loading.
            if self.lastArtworkKey == key {
                self.model.artwork = artwork?.thumbnail
                self.model.artworkLarge = artwork?.full
            }
        }
    }

    private func updateAccessibility() {
        let label: String
        if !model.hasTrack {
            label = NSLocalizedString("No music playing", comment: "")
        } else if model.isPlaying {
            label = String(format: NSLocalizedString("Playing %@", comment: ""), model.displayText)
        } else {
            label = String(format: NSLocalizedString("Paused %@", comment: ""), model.displayText)
        }
        statusItem.button?.setAccessibilityLabel(label)
    }

    // MARK: - Clicks

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }

        // Don't leave the popup floating over a menu or while interacting.
        hoverPopup.setHovering(false, relativeTo: nil)

        if event.type == .rightMouseUp {
            showContextMenu()
            return
        }

        // Option-click skips to the next track, no double-click delay.
        if event.modifierFlags.contains(.option) {
            singleClickTimer?.invalidate()
            singleClickTimer = nil
            music.nextTrack()
            refreshSoon()
            return
        }

        switch event.clickCount {
        case 1:
            // Delay so a second click can cancel the play/pause.
            singleClickTimer = Timer.scheduledTimer(
                withTimeInterval: NSEvent.doubleClickInterval,
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.music.playPause()
                    self?.refreshSoon()
                }
            }
        case 2:
            singleClickTimer?.invalidate()
            singleClickTimer = nil
            music.openPlayerApp()
        default:
            break
        }
    }

    /// Give the player a moment to apply the command before reconciling.
    /// Fallback only — cancelled if the player's notification arrives first.
    private func refreshSoon() {
        pendingReconcile?.cancel()
        pendingReconcile = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let openTitle = music.activePlayer == .spotify
            ? NSLocalizedString("Open Spotify", comment: "")
            : NSLocalizedString("Open Music", comment: "")
        let openItem = NSMenuItem(title: openTitle, action: #selector(openPlayer), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: NSLocalizedString("Settings…", comment: ""), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let aboutItem = NSMenuItem(title: NSLocalizedString("About MusicBar", comment: ""), action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: NSLocalizedString("Quit MusicBar", comment: ""), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // Assign temporarily so left clicks keep their custom behavior.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openPlayer() {
        music.openPlayerApp()
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// Lets clicks fall through to the status item button underneath while still
/// reporting hover via a tracking area (tracking ignores hitTest).
private final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChange: ((Bool) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
