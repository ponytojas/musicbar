import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let music = MusicController()
    private let model = TrackModel()
    private let waveformModel = AudioWaveformModel()
    private let settingsWindow = SettingsWindowController()
    private lazy var waveformCapture = AudioWaveformCapture(
        onLevels: { [weak self] levels in
            Task { @MainActor [weak self] in self?.waveformModel.ingest(levels) }
        },
        onStopped: { [weak self] in
            Task { @MainActor [weak self] in self?.waveformModel.reset() }
        }
    )
    private lazy var hoverPopup = HoverPopupController(
        model: model,
        actions: PopupActions(
            playPause: { [weak self] in
                self?.music.playPause()
                self?.refreshSoon()
            },
            previous: { [weak self] in
                self?.music.previousTrack()
                self?.refreshSoon()
            },
            next: { [weak self] in
                self?.music.nextTrack()
                self?.refreshSoon()
            },
            toggleFavorite: { [weak self] in self?.toggleFavorite() },
            addToPlaylist: { [weak self] playlist in self?.addCurrentTrack(to: playlist) },
            seek: { [weak self] position in self?.seek(to: position) },
            toggleShuffle: { [weak self] in self?.toggleShuffle() },
            cycleRepeat: { [weak self] in self?.cycleRepeat() },
            selectOutput: { [weak self] device in self?.selectOutput(device) }
        )
    ) { [weak self] in
        self?.loadLargeArtworkIfNeeded()
        self?.loadPopupDetails(includePlaylists: true)
    }

    private var singleClickTimer: Timer?
    private var scrollMonitor: Any?
    private var scrollAccumulator: CGFloat = 0
    private var refreshTimer: Timer?
    private var lastArtworkKey: String?
    private var artworkSourceData: Data?
    private var artworkTask: Task<Void, Never>?
    private var largeArtworkTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var sleepTimerTask: Task<Void, Never>?
    private var sleepTimerEnd: Date?
    private var sleepTimerMinutes = 0
    private var isRefreshing = false
    /// Post-command reconcile; cancelled when the player's own notification
    /// arrives first so we don't fetch the same state twice.
    private var pendingReconcile: Task<Void, Never>?
    private var settingsCancellables: Set<AnyCancellable> = []

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        observeScrollWheel()
        observePlayerNotifications()
        observePlayerLifecycle()
        observeScreenState()
        observeWaveformSetting()
        runFirstLaunchPermissionFlow()
        Task { await refresh() }

        // Fallback reconciliation in case a notification is missed. Skipped
        // while the screen is locked/asleep; the wake handler reconciles.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.model.screenActive else { return }
                await self.refresh()
            }
        }
        refreshTimer?.tolerance = 30
    }

    // MARK: - Setup

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let hosting = HoverTrackingHostingView(rootView: StatusBarView(model: model, waveform: waveformModel))
        hosting.passesClicksThrough = true
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
                let state = (note.userInfo?["Player State"] as? String) ?? "Stopped"
                let title = (note.userInfo?["Name"] as? String) ?? ""
                let artist = (note.userInfo?["Artist"] as? String) ?? ""
                Task { @MainActor in
                    self?.handlePlayerInfo(title: title, artist: artist, state: state, from: player)
                }
            }
        }
    }

    /// Player launch/termination is a more useful reconciliation point than a
    /// frequent timer, and lets a newly launched player request permission once.
    private func observePlayerLifecycle() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleIdentifier = application.bundleIdentifier,
                      let player = PlayerApp(rawValue: bundleIdentifier)
                else { return }

                Task { @MainActor in
                    guard let self else { return }
                    self.music.clearPermissionFailures(for: player)
                    if name == NSWorkspace.didLaunchApplicationNotification {
                        self.prepareAutomationPermissions(for: [player])
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    guard !Task.isCancelled else { return }
                    await self.refresh()
                }
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

    private func observeWaveformSetting() {
        AppSettings.shared.$showEqualizer
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateWaveformCapture() }
            }
            .store(in: &settingsCancellables)
        model.$isPlaying
            .combineLatest(AppSettings.shared.$collapseAfterPauseMinutes)
            .sink { [weak self] isPlaying, minutes in
                Task { @MainActor [weak self] in self?.scheduleCollapse(isPlaying: isPlaying, minutes: minutes) }
            }
            .store(in: &settingsCancellables)
        AppSettings.shared.$playerMode
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refresh() }
            }
            .store(in: &settingsCancellables)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    /// Shrinks the item to the music note after a long pause; any change in
    /// play state or in the setting restores it.
    private func scheduleCollapse(isPlaying: Bool, minutes: Int) {
        collapseTask?.cancel()
        collapseTask = nil
        if model.isCollapsed { model.isCollapsed = false }
        guard !isPlaying, minutes > 0 else { return }
        collapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            self?.model.isCollapsed = true
        }
    }

    @objc nonisolated private func accessibilityDisplayOptionsChanged() {
        Task { @MainActor in self.updateWaveformCapture() }
    }

    @objc nonisolated private func screenBecameInactive() {
        Task { @MainActor in
            self.model.screenActive = false
            self.updateWaveformCapture()
        }
    }

    @objc nonisolated private func screenBecameActive() {
        Task { @MainActor in
            self.model.screenActive = true
            self.music.clearPermissionFailures()
            // Catch up on anything missed while refreshes were paused.
            await self.refresh()
        }
    }

    // MARK: - Automation permission (first run)

    private static let automationExplainedKey = "didExplainAutomation"
    private static let automationPromptedPrefix = "didRequestAutomation."
    private static let errNotPermitted: OSStatus = -1743
    private static let errWouldRequireConsent: OSStatus = -1744

    private func runFirstLaunchPermissionFlow() {
        prepareAutomationPermissions(for: PlayerApp.allCases.filter(\.isRunning))
    }

    /// TCC grants Automation per controlled application. Explain once, then
    /// request each player only the first time that player is encountered.
    private func prepareAutomationPermissions(for players: [PlayerApp]) {
        let defaults = UserDefaults.standard
        let unprompted = players.filter {
            !defaults.bool(forKey: Self.automationPromptedPrefix + $0.rawValue)
        }
        guard !unprompted.isEmpty else { return }

        let statuses = Dictionary(uniqueKeysWithValues: unprompted.map {
            ($0, automationPermission(for: $0.rawValue, askIfNeeded: false))
        })

        if statuses.values.contains(Self.errWouldRequireConsent),
           !defaults.bool(forKey: Self.automationExplainedKey) {
            showPermissionExplainer()
            defaults.set(true, forKey: Self.automationExplainedKey)
        }

        var permissionDenied = false
        for player in unprompted {
            let status = statuses[player] ?? noErr
            let finalStatus = status == Self.errWouldRequireConsent
                ? automationPermission(for: player.rawValue, askIfNeeded: true)
                : status
            permissionDenied = permissionDenied || finalStatus == Self.errNotPermitted
            defaults.set(true, forKey: Self.automationPromptedPrefix + player.rawValue)
        }

        if permissionDenied {
            showPermissionDeniedAlert()
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
        NSApp.activate()
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
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - State

    private func handlePlayerInfo(title: String, artist: String, state: String, from player: PlayerApp) {
        guard AppSettings.shared.playerMode.players.contains(player) else { return }
        // The notification carries the fresh state; a pending post-command
        // reconcile would only re-fetch the same thing.
        pendingReconcile?.cancel()
        pendingReconcile = nil

        if state == "Stopped" {
            // Another player might still be active; re-scan.
            if player == music.activePlayer { Task { await refresh() } }
            return
        }
        music.activePlayer = player
        model.update(
            title: title,
            artist: artist,
            isPlaying: state == "Playing"
        )
        updateWaveformCapture()
        refreshArtworkIfNeeded()
        updateAccessibility()
        // Play/pause or a new track while the popup is open moves the clock.
        if hoverPopup.isShown { loadPopupDetails(includePlaylists: false) }
    }

    private func refresh() async {
        // Coalesce: a refresh already in flight will land the same state.
        guard !isRefreshing else { return }
        let signpost = PerformanceSignposts.begin("Player Refresh")
        defer { PerformanceSignposts.end("Player Refresh", signpost) }
        isRefreshing = true
        defer { isRefreshing = false }

        if let nowPlaying = await music.fetchNowPlaying() {
            model.update(title: nowPlaying.title, artist: nowPlaying.artist, isPlaying: nowPlaying.isPlaying)
            updateWaveformCapture()
            refreshArtworkIfNeeded()
        } else {
            waveformCapture.capture(nil)
            cancelArtworkWork()
            model.clear()
            lastArtworkKey = nil
        }
        updateAccessibility()
    }

    /// Keep the system-audio tap alive only while its pixels are visible and
    /// moving. Pausing, hiding the equalizer, locking the screen, or turning on
    /// Reduce Motion (static bars) tears down the aggregate device and its
    /// realtime callback.
    private func updateWaveformCapture() {
        let shouldCapture = AppSettings.shared.showEqualizer
            && model.isPlaying
            && model.screenActive
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        waveformCapture.capture(shouldCapture ? music.activePlayer : nil)
    }

    /// Fetch cover art only when the track actually changed — playerInfo
    /// notifications also fire on plain play/pause.
    private func refreshArtworkIfNeeded() {
        let key = "\(music.activePlayer.rawValue)|\(model.title)|\(model.artist)"
        guard key != lastArtworkKey else { return }
        artworkTask?.cancel()
        largeArtworkTask?.cancel()
        artworkTask = nil
        largeArtworkTask = nil
        artworkSourceData = nil
        model.artwork = nil
        model.artworkLarge = nil
        model.isFavorited = nil
        lastArtworkKey = key
        let title = model.title
        let artist = model.artist
        artworkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let artwork = await self.music.fetchArtwork(title: title, artist: artist)
            guard !Task.isCancelled else { return }
            // The track may have changed while the artwork was loading.
            guard self.lastArtworkKey == key else { return }
            if let artwork, self.popupWanted {
                // The card is open or opening: decode its cover first and
                // publish both together so it never shows the thumbnail.
                let large = await MusicController.decodeArtwork(from: artwork.encodedData, maxPixelSize: 512)
                guard !Task.isCancelled, self.lastArtworkKey == key else { return }
                self.model.artworkLarge = large
                // Keep the data so a failed decode can retry on the next open.
                if large == nil { self.artworkSourceData = artwork.encodedData }
            } else {
                self.artworkSourceData = artwork?.encodedData
            }
            self.model.artwork = artwork?.thumbnail
            // A transient failure may retry on the next reconciliation.
            if artwork == nil { self.lastArtworkKey = nil }
        }
    }

    private func loadLargeArtworkIfNeeded() {
        guard model.artworkLarge == nil,
              largeArtworkTask == nil,
              let data = artworkSourceData,
              let key = lastArtworkKey
        else { return }

        largeArtworkTask = Task { @MainActor [weak self] in
            let image = await MusicController.decodeArtwork(from: data, maxPixelSize: 512)
            guard let self else { return }
            defer {
                if self.lastArtworkKey == key { self.largeArtworkTask = nil }
            }
            guard !Task.isCancelled, self.lastArtworkKey == key else { return }
            self.model.artworkLarge = image
            self.artworkSourceData = nil
        }
    }

    /// Everything the card shows beyond the track itself. Fetched as soon as
    /// the pointer lands on the item, so it's usually ready before the card
    /// appears, and again when the player reports a change while it's open.
    /// Each piece is published as it arrives; the playlist listing (the
    /// slowest script) comes last and is only re-read when the card opens.
    private func loadPopupDetails(includePlaylists: Bool) {
        progressTask?.cancel()
        progressTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let progress = await self.music.fetchProgress()
            guard !Task.isCancelled, self.popupWanted else { return }
            self.model.progress = progress

            let favorited = await self.music.fetchFavorited()
            guard !Task.isCancelled, self.popupWanted else { return }
            if self.model.isFavorited != favorited { self.model.isFavorited = favorited }

            let modes = await self.music.fetchPlaybackModes()
            guard !Task.isCancelled, self.popupWanted else { return }
            if self.model.playbackModes != modes { self.model.playbackModes = modes }

            let isAppleMusic = self.music.activePlayer == .appleMusic
            var playlists = isAppleMusic ? self.model.playlists : []
            var devices = isAppleMusic ? self.model.outputDevices : []
            if includePlaylists {
                playlists = await self.music.fetchPlaylists()
                devices = await self.music.fetchOutputDevices()
            }
            guard !Task.isCancelled, self.popupWanted else { return }
            if self.model.playlists != playlists { self.model.playlists = playlists }
            if self.model.outputDevices != devices { self.model.outputDevices = devices }
        }
    }

    /// The card is open or about to open.
    private var popupWanted: Bool { hoverPopup.isShown || model.isHovering }

    private func addCurrentTrack(to playlist: Playlist) {
        Task {
            switch await music.addCurrentTrack(to: playlist) {
            case .added:
                showPopupNotice(String(format: NSLocalizedString("Added to %@", comment: ""), playlist.name))
            case .notInLibrary:
                showPopupNotice(NSLocalizedString("Add the song to your library first", comment: ""))
            case .failed:
                showPopupNotice(String(format: NSLocalizedString("Couldn't add to %@", comment: ""), playlist.name))
            }
        }
    }

    /// Shown for two seconds under the card's controls; the card stays open
    /// meanwhile so the result is visible even after the menu closes.
    private func showPopupNotice(_ text: String) {
        noticeTask?.cancel()
        model.popupNotice = text
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.model.popupNotice = nil
        }
    }

    /// Optimistic; restores the list and says so if Music refuses.
    private func selectOutput(_ device: OutputDevice) {
        let previous = model.outputDevices
        model.outputDevices = previous.map { OutputDevice(id: $0.id, name: $0.name, isSelected: $0.id == device.id) }
        Task {
            guard !(await music.selectOutput(device)) else { return }
            model.outputDevices = previous
            showPopupNotice(String(format: NSLocalizedString("Couldn't switch to %@", comment: ""), device.name))
        }
    }

    private func toggleShuffle() {
        guard var modes = model.playbackModes else { return }
        modes.shuffle.toggle()
        model.playbackModes = modes
        music.setShuffle(modes.shuffle)
    }

    /// Off → all → one (Music only) → off.
    private func cycleRepeat() {
        guard var modes = model.playbackModes else { return }
        modes.repeatMode = switch modes.repeatMode {
        case .off: .all
        case .all: music.activePlayer == .appleMusic ? .one : .off
        case .one: .off
        }
        model.playbackModes = modes
        music.setRepeat(modes.repeatMode)
    }

    /// Optimistic: moves the bar at once instead of waiting for a reload.
    private func seek(to position: TimeInterval) {
        music.seek(to: position)
        guard let progress = model.progress else { return }
        model.progress = PlaybackProgress(
            position: position,
            duration: progress.duration,
            start: Date().addingTimeInterval(-position)
        )
    }

    /// Optimistic: flips the heart at once and reverts if Music refuses.
    private func toggleFavorite() {
        let favorited = !(model.isFavorited ?? false)
        let key = lastArtworkKey
        model.isFavorited = favorited
        Task {
            guard !(await music.setFavorited(favorited)), lastArtworkKey == key else { return }
            model.isFavorited = !favorited
        }
    }

    private func cancelArtworkWork() {
        artworkTask?.cancel()
        artworkTask = nil
        largeArtworkTask?.cancel()
        largeArtworkTask = nil
        artworkSourceData = nil
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
        hoverPopup.dismiss()

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

        // Shift-click goes back a track, same immediacy as Option-click.
        if event.modifierFlags.contains(.shift) {
            singleClickTimer?.invalidate()
            singleClickTimer = nil
            music.previousTrack()
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

    /// Scrolling over the item changes the player's volume. The hosting view
    /// passes hit-testing through, so a local monitor catches the events.
    private func observeScrollWheel() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleScroll(event) ?? false }
            return handled ? nil : event
        }
    }

    private func handleScroll(_ event: NSEvent) -> Bool {
        guard event.window === statusItem.button?.window else { return false }
        // Physical direction regardless of natural scrolling: up is louder.
        var delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        // Trackpads report points; scale them down to wheel-like steps.
        if event.hasPreciseScrollingDeltas { delta /= 8 }
        scrollAccumulator += delta
        let steps = Int(scrollAccumulator)
        guard steps != 0 else { return true }
        scrollAccumulator -= CGFloat(steps)
        Task {
            guard let volume = await music.changeVolume(by: steps * 5) else { return }
            // The card is usually open while the pointer is over the item.
            showPopupNotice(String(format: NSLocalizedString("Volume %d%%", comment: ""), volume))
        }
        return true
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
        if model.hasTrack, music.activePlayer == .appleMusic {
            let favoriteItem = NSMenuItem(title: NSLocalizedString("Favorite Song", comment: ""), action: #selector(favoriteSong), keyEquivalent: "")
            favoriteItem.target = self
            favoriteItem.state = model.isFavorited == true ? .on : .off
            menu.addItem(favoriteItem)
            let showItem = NSMenuItem(title: NSLocalizedString("Show in Music", comment: ""), action: #selector(showInMusic), keyEquivalent: "")
            showItem.target = self
            menu.addItem(showItem)
        }
        if model.hasTrack, music.activePlayer == .spotify {
            let linkItem = NSMenuItem(title: NSLocalizedString("Copy Song Link", comment: ""), action: #selector(copySongLink), keyEquivalent: "")
            linkItem.target = self
            menu.addItem(linkItem)
        }
        menu.addItem(.separator())
        menu.addItem(sleepTimerMenuItem())
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

    private func sleepTimerMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: NSLocalizedString("Sleep Timer", comment: ""), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if let end = sleepTimerEnd {
            // No action, so the menu shows it disabled.
            submenu.addItem(NSMenuItem(
                title: String(format: NSLocalizedString("Pauses at %@", comment: ""), end.formatted(date: .omitted, time: .shortened)),
                action: nil,
                keyEquivalent: ""
            ))
            submenu.addItem(.separator())
        }
        for minutes in [0, 15, 30, 60] {
            let title = minutes == 0
                ? NSLocalizedString("Off", comment: "")
                : String(format: NSLocalizedString("%d minutes", comment: ""), minutes)
            let option = NSMenuItem(title: title, action: #selector(setSleepTimer(_:)), keyEquivalent: "")
            option.target = self
            option.tag = minutes
            option.state = sleepTimerMinutes == minutes ? .on : .off
            submenu.addItem(option)
        }
        item.submenu = submenu
        return item
    }

    @objc private func setSleepTimer(_ sender: NSMenuItem) {
        let minutes = sender.tag
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEnd = nil
        sleepTimerMinutes = minutes
        guard minutes > 0 else { return }
        sleepTimerEnd = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled, let self else { return }
            self.music.pause()
            self.sleepTimerEnd = nil
            self.sleepTimerMinutes = 0
        }
    }

    @objc private func showInMusic() {
        music.revealCurrentTrack()
    }

    @objc private func favoriteSong() {
        toggleFavorite()
    }

    @objc private func copySongLink() {
        Task {
            guard let url = await music.spotifyTrackLink() else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
    }

    @objc private func openPlayer() {
        music.openPlayerApp()
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// Reports hover through a tracking area (tracking ignores hitTest). The
/// status item passes clicks through to its button underneath; the hover
/// card takes the first click even though its panel never becomes key.
final class HoverTrackingHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChange: ((Bool) -> Void)?
    var passesClicksThrough = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        passesClicksThrough ? nil : super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
