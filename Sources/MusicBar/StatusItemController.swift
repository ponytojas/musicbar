import AppKit
import Combine
import SwiftUI

/// Owns the menu bar item and keeps it in step with the players. This file
/// is the state: what is playing, its cover, the equalizer. The card's
/// controls, pointer and keyboard input, and the context menu are in the
/// +Card, +Input and +Menu extensions.
@MainActor
final class StatusItemController: NSObject {
    let statusItem: NSStatusItem
    let music = MusicController()
    let model = TrackModel()
    let settingsWindow = SettingsWindowController()
    lazy var welcomeWindow = WelcomeWindowController { [weak self] in self?.settingsWindow.show() }
    private let waveformModel = AudioWaveformModel()
    private let notifier = TrackNotifier()
    private lazy var waveformCapture = AudioWaveformCapture(
        onLevels: { [weak self] levels in
            Task { @MainActor [weak self] in self?.waveformModel.ingest(levels) }
        },
        onStopped: { [weak self] in
            Task { @MainActor [weak self] in self?.waveformModel.reset() }
        },
        onAvailability: { [weak self] available in
            Task { @MainActor [weak self] in self?.captureAvailabilityChanged(available) }
        }
    )
    lazy var hoverPopup = HoverPopupController(
        model: model,
        actions: PopupActions(
            playPause: { [weak self] in self?.togglePlayback() },
            previous: { [weak self] in self?.skip(forward: false) },
            next: { [weak self] in self?.skip(forward: true) },
            toggleFavorite: { [weak self] in self?.toggleFavorite() },
            addToPlaylist: { [weak self] playlist in self?.addCurrentTrack(to: playlist) },
            seek: { [weak self] position in self?.seek(to: position) },
            setVolume: { [weak self] volume in self?.setVolume(volume) },
            changeVolume: { [weak self] delta in self?.changeVolume(by: delta) },
            toggleShuffle: { [weak self] in self?.toggleShuffle() },
            cycleRepeat: { [weak self] in self?.cycleRepeat() },
            selectOutput: { [weak self] device in self?.selectOutput(device) }
        )
    ) { [weak self] in
        self?.loadLargeArtworkIfNeeded()
        self?.loadPopupDetails(includePlaylists: true)
    }
    lazy var sleepTimer: SleepTimer = SleepTimer(
        onFire: { [weak self] in self?.music.pause() },
        onChange: { [weak self] in
            guard let self else { return }
            self.model.sleepTimerActive = self.sleepTimer.isActive
        }
    )

    lazy var hotKeys = GlobalHotKeys { [weak self] action in self?.handleHotKey(action) }

    var singleClickTimer: Timer?
    var scrollMonitor: Any?
    var scrollAccumulator: CGFloat = 0
    private var refreshTimer: Timer?
    private var simulationTimer: Timer?
    /// The song on display; nil with nothing queued.
    private var currentTrack: TrackIdentity?
    /// That song's key, fixed when it started: what in-flight work compares
    /// against to learn the song changed under it.
    private(set) var currentTrackKey: String?
    /// Music persistent ID or Spotify URI of that song, when known.
    private var currentTrackID: String?
    private var artworkSourceData: Data?
    private var artworkAttempts = 0
    private var artworkTask: Task<Void, Never>?
    private var largeArtworkTask: Task<Void, Never>?
    var progressTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    var noticeTask: Task<Void, Never>?
    var volumeTask: Task<Void, Never>?
    var pendingVolumeDelta = 0
    var pendingVolume: Int?
    var recentTracks = StatusItemController.loadRecentTracks()
    private static let recentTracksKey = "recentTracks"
    /// The system couldn't start the audio capture (permission refused, no
    /// audio process yet…); the bars run simulated until it can.
    private(set) var captureFailed = false
    /// A newer release found by an update check.
    var availableUpdate: String?
    private var isRefreshing = false
    private var refreshRequested = false
    /// Bumped by every player notification. A refresh that was reading the
    /// players meanwhile holds older news and steps aside.
    private var stateGeneration = 0
    /// The first refresh has landed; songs after it are "changes" worth a
    /// notification, the one playing at launch isn't.
    private var didInitialSync = false
    /// Post-command reconcile; cancelled when the player's own notification
    /// arrives first so we don't fetch the same state twice.
    var pendingReconcile: Task<Void, Never>?
    private var settingsCancellables: Set<AnyCancellable> = []

    /// A song with no cover gets one more try, not one every reconcile.
    private static let maximumArtworkAttempts = 2

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        observeScrollWheel()
        observePlayerNotifications()
        observePlayerLifecycle()
        observeScreenState()
        observeSettings()
        configureNotifications()
        model.sleepTimerActive = sleepTimer.isActive
        music.onPermissionChange = { [weak self] in self?.updateAccessibility() }
        Task {
            await AutomationPermission.prepare(for: PlayerApp.allCases.filter(\.isRunning))
            // After the permission alerts, which are modal and would cover it.
            welcomeWindow.showOnFirstLaunch()
            await refresh()
            checkForUpdatesIfDue()
        }

        // Fallback reconciliation in case a notification is missed. Skipped
        // while the screen is locked/asleep; the wake handler reconciles.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.model.screenActive else { return }
                await self.refresh()
                self.checkForUpdatesIfDue()
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
        // VoiceOver's Actions menu: what the pointer does with modifiers.
        button.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: NSLocalizedString("Next Track", comment: "")) { [weak self] in
                MainActor.assumeIsolated { self?.skip(forward: true) }
                return true
            },
            NSAccessibilityCustomAction(name: NSLocalizedString("Previous Track", comment: "")) { [weak self] in
                MainActor.assumeIsolated { self?.skip(forward: false) }
                return true
            },
            NSAccessibilityCustomAction(name: NSLocalizedString("Show or hide the card", comment: "")) { [weak self] in
                MainActor.assumeIsolated { self?.handleHotKey(.toggleCard) }
                return true
            },
            NSAccessibilityCustomAction(name: NSLocalizedString("Show Menu", comment: "")) { [weak self] in
                MainActor.assumeIsolated { self?.showContextMenu() }
                return true
            },
        ])

        let hosting = HoverTrackingHostingView(rootView: StatusBarView(model: model, waveform: waveformModel))
        hosting.passesClicksThrough = true
        hosting.onHoverChange = { [weak self] hovering in
            guard let self else { return }
            self.model.isHovering = hovering
            // Leaving always reaches the card, so one opened from the
            // keyboard still closes by the pointer rules.
            guard !hovering || AppSettings.shared.showHoverCard else { return }
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

    private func configureNotifications() {
        notifier.onNextTrack = { [weak self] in self?.skip(forward: true) }
        notifier.onOpenPlayer = { [weak self] in self?.music.openPlayerApp() }
        notifier.install()
    }

    private func observePlayerNotifications() {
        // Both players post on every play/pause/track change. No polling.
        for player in PlayerApp.allCases {
            DistributedNotificationCenter.default().addObserver(
                forName: player.playerInfoNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let userInfo = note.userInfo ?? [:]
                let state = (userInfo["Player State"] as? String) ?? "Stopped"
                let nowPlaying = MusicController.NowPlaying(
                    title: (userInfo["Name"] as? String) ?? "",
                    artist: (userInfo["Artist"] as? String) ?? "",
                    album: (userInfo["Album"] as? String) ?? "",
                    trackID: MusicController.trackID(fromNotification: userInfo, player: player),
                    isPlaying: state == "Playing"
                )
                Task { @MainActor in
                    self?.handlePlayerInfo(nowPlaying, stopped: state == "Stopped", from: player)
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
                    self.updateItemVisibility()
                    self.music.clearPermissionFailures(for: player)
                    if name == NSWorkspace.didLaunchApplicationNotification {
                        await AutomationPermission.prepare(for: [player])
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

    private func observeSettings() {
        let settings = AppSettings.shared
        // @Published emits before the new value is stored, so each sink
        // hops to the next main-actor turn and reads the settings there.
        settings.$showEqualizer
            .removeDuplicates()
            .combineLatest(settings.$equalizerStyle.removeDuplicates())
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateWaveformCapture() }
            }
            .store(in: &settingsCancellables)
        settings.$equalizerSensitivity
            .sink { [weak self] sensitivity in
                Task { @MainActor [weak self] in self?.waveformModel.sensitivity = CGFloat(sensitivity) }
            }
            .store(in: &settingsCancellables)
        model.$isPlaying
            .combineLatest(settings.$collapseAfterPauseMinutes)
            .sink { [weak self] isPlaying, minutes in
                Task { @MainActor [weak self] in self?.scheduleCollapse(isPlaying: isPlaying, minutes: minutes) }
            }
            .store(in: &settingsCancellables)
        settings.$globalShortcuts
            .combineLatest(settings.$shortcuts, settings.$recordingShortcut)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.registerHotKeys() }
            }
            .store(in: &settingsCancellables)
        settings.$playerMode
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refresh() }
            }
            .store(in: &settingsCancellables)
        settings.$hideWhenNoPlayer
            .combineLatest(settings.$playerMode)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateItemVisibility() }
            }
            .store(in: &settingsCancellables)
        settings.$showHoverCard
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    if !AppSettings.shared.showHoverCard { self?.hoverPopup.dismiss() }
                }
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

    /// With "hide when no player is open" on, the item leaves the menu bar
    /// until Music or Spotify is launched.
    private func updateItemVisibility() {
        let visible = Self.shouldShowItem(
            hideWhenNoPlayer: AppSettings.shared.hideWhenNoPlayer,
            anyPlayerRunning: AppSettings.shared.playerMode.players.contains(where: \.isRunning)
        )
        if statusItem.isVisible != visible { statusItem.isVisible = visible }
    }

    static func shouldShowItem(hideWhenNoPlayer: Bool, anyPlayerRunning: Bool) -> Bool {
        !hideWhenNoPlayer || anyPlayerRunning
    }

    // MARK: - State

    private func handlePlayerInfo(_ nowPlaying: MusicController.NowPlaying, stopped: Bool, from player: PlayerApp) {
        guard AppSettings.shared.playerMode.players.contains(player) else { return }
        // The notification carries the fresh state; a pending post-command
        // reconcile would only re-fetch the same thing.
        pendingReconcile?.cancel()
        pendingReconcile = nil

        if stopped {
            // Another player might still be active; re-scan.
            if player == music.activePlayer { Task { await refresh() } }
            return
        }
        guard MusicController.shouldAdopt(
            notificationFrom: player,
            isPlaying: nowPlaying.isPlaying,
            activePlayer: music.activePlayer,
            activeIsPlaying: model.isPlaying
        ) else { return }

        stateGeneration += 1
        apply(nowPlaying, from: player)
        // Play/pause or a new track while the popup is open moves the clock.
        if hoverPopup.isShown { loadPopupDetails(includePlaylists: false) }
    }

    /// Reads the players directly. Calls made while one is running fold
    /// into a single follow-up pass, so the last request is never lost.
    func refresh() async {
        guard !isRefreshing else {
            refreshRequested = true
            return
        }
        let signpost = PerformanceSignposts.begin("Player Refresh")
        defer { PerformanceSignposts.end("Player Refresh", signpost) }
        isRefreshing = true
        defer { isRefreshing = false }

        repeat {
            refreshRequested = false
            let generation = stateGeneration
            let candidate = await music.fetchNowPlaying()
            // A notification landed while the scripts ran: it is newer.
            guard generation == stateGeneration else { continue }
            if let candidate {
                apply(candidate.nowPlaying, from: candidate.player)
            } else {
                model.clear()
                currentTrackID = nil
                updateWaveformCapture()
                trackDidUpdate()
                updateAccessibility()
            }
        } while refreshRequested
        didInitialSync = true
    }

    private func apply(_ nowPlaying: MusicController.NowPlaying, from player: PlayerApp) {
        // More news about the song on display may leave the album or ID
        // out; don't let that erase what is already known.
        let incoming = TrackIdentity(
            player: player,
            title: nowPlaying.title,
            artist: nowPlaying.artist,
            album: nowPlaying.album
        )
        let sameSong = incoming.flatMap { new in currentTrack.map(new.isSameSong(as:)) } ?? false
        music.activePlayer = player
        model.update(
            title: nowPlaying.title,
            artist: nowPlaying.artist,
            album: sameSong && nowPlaying.album.isEmpty ? model.album : nowPlaying.album,
            isPlaying: nowPlaying.isPlaying
        )
        if !sameSong || nowPlaying.trackID != nil { currentTrackID = nowPlaying.trackID }
        updateWaveformCapture()
        trackDidUpdate()
        updateAccessibility()
    }

    /// Runs after every state update: notices a new song, or gives a song
    /// whose cover failed to load another try.
    private func trackDidUpdate() {
        let track = TrackIdentity(
            player: music.activePlayer,
            title: model.title,
            artist: model.artist,
            album: model.album
        )
        if let track, let currentTrack, track.isSameSong(as: currentTrack) {
            // Remember an album that arrived late, without a new key.
            if currentTrack.album.isEmpty { self.currentTrack = track }
            if model.artwork == nil, artworkTask == nil, artworkAttempts < Self.maximumArtworkAttempts {
                loadArtwork(notify: false)
            }
            return
        }
        guard track != nil || currentTrack != nil else { return }
        currentTrack = track
        let key = track?.key
        currentTrackKey = key
        cancelArtworkWork()
        artworkAttempts = 0
        model.artwork = nil
        model.artworkLarge = nil
        model.isFavorited = nil
        sleepTimer.trackDidChange()
        guard key != nil else { return }
        recordRecentTrack()
        let notify = didInitialSync && model.isPlaying && AppSettings.shared.notifyOnTrackChange
        loadArtwork(notify: notify)
    }

    // MARK: - Equalizer

    /// Keep the system-audio tap alive only while its pixels are visible and
    /// moving. Pausing, hiding the equalizer, locking the screen, or turning on
    /// Reduce Motion (static bars) tears down the aggregate device and its
    /// realtime callback. The simulated style never opens a tap at all.
    private func updateWaveformCapture() {
        let style = AppSettings.shared.equalizerStyle
        let shouldCapture = equalizerIsMoving && style.capturesAudio
        waveformCapture.capture(shouldCapture ? music.activePlayer : nil, spectrum: style == .spectrum)
        // Nothing is being attempted any more, so nothing is failing.
        if !shouldCapture { captureFailed = false }
        updateSimulation()
    }

    private var equalizerIsMoving: Bool {
        AppSettings.shared.showEqualizer
            && model.isPlaying
            && model.screenActive
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func captureAvailabilityChanged(_ available: Bool) {
        captureFailed = !available
        // Not updateWaveformCapture(): that would retry a failing capture
        // in a loop. The next play/pause or track change retries it.
        updateSimulation()
    }

    /// Drives the bars from a timer when they aren't fed real audio: the
    /// simulated style, or a capture the system refused.
    private func updateSimulation() {
        let simulate = equalizerIsMoving && (!AppSettings.shared.equalizerStyle.capturesAudio || captureFailed)
        guard simulate != (simulationTimer != nil) else { return }
        simulationTimer?.invalidate()
        simulationTimer = nil
        guard simulate else {
            if !equalizerIsMoving { waveformModel.reset() }
            return
        }
        simulationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.waveformModel.ingest(SimulatedWaveform.levels(at: Date.timeIntervalSinceReferenceDate))
            }
        }
        simulationTimer?.tolerance = 0.01
    }

    // MARK: - Artwork

    private func loadArtwork(notify: Bool) {
        guard let key = currentTrackKey else { return }
        artworkAttempts += 1
        let title = model.title
        let artist = model.artist
        let album = model.album
        artworkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let artwork = await self.music.fetchArtwork(title: title, artist: artist)
            // The track may have changed while the artwork was loading.
            guard !Task.isCancelled, self.currentTrackKey == key else { return }
            // Only while this is still the song on display: after a change
            // the property already belongs to the next song's task.
            defer {
                if self.currentTrackKey == key { self.artworkTask = nil }
            }
            // Sent now rather than at the change so the banner has its
            // cover; a song skipped before this never gets one.
            if notify {
                self.notifier.post(title: title, artist: artist, album: album, artworkData: artwork?.encodedData)
            }
            if let artwork, self.popupWanted {
                // The card is open or opening: decode its cover first and
                // publish both together so it never shows the thumbnail.
                let large = await MusicController.decodeArtwork(from: artwork.encodedData, maxPixelSize: 512)
                guard !Task.isCancelled, self.currentTrackKey == key else { return }
                self.model.artworkLarge = large
                // Keep the data so a failed decode can retry on the next open.
                if large == nil { self.artworkSourceData = artwork.encodedData }
            } else {
                self.artworkSourceData = artwork?.encodedData
            }
            self.model.artwork = artwork?.thumbnail
        }
    }

    private func loadLargeArtworkIfNeeded() {
        guard model.artworkLarge == nil,
              largeArtworkTask == nil,
              let data = artworkSourceData,
              let key = currentTrackKey
        else { return }

        largeArtworkTask = Task { @MainActor [weak self] in
            let image = await MusicController.decodeArtwork(from: data, maxPixelSize: 512)
            guard let self else { return }
            defer {
                if self.currentTrackKey == key { self.largeArtworkTask = nil }
            }
            guard !Task.isCancelled, self.currentTrackKey == key else { return }
            self.model.artworkLarge = image
            self.artworkSourceData = nil
        }
    }

    private func cancelArtworkWork() {
        artworkTask?.cancel()
        artworkTask = nil
        largeArtworkTask?.cancel()
        largeArtworkTask = nil
        artworkSourceData = nil
    }

    // MARK: - Recently played

    private static func loadRecentTracks() -> [RecentTrack] {
        guard let data = UserDefaults.standard.data(forKey: recentTracksKey) else { return [] }
        return (try? JSONDecoder().decode([RecentTrack].self, from: data)) ?? []
    }

    private func recordRecentTrack() {
        let track = RecentTrack(
            title: model.title,
            artist: model.artist,
            player: music.activePlayer.rawValue,
            trackID: currentTrackID
        )
        recentTracks = RecentTrack.adding(track, to: recentTracks)
        saveRecentTracks()
    }

    func clearRecentTracks() {
        recentTracks = []
        saveRecentTracks()
    }

    private func saveRecentTracks() {
        if let data = try? JSONEncoder().encode(recentTracks) {
            UserDefaults.standard.set(data, forKey: Self.recentTracksKey)
        }
    }

    /// Replays a song from the history. When the player can't start it (a
    /// streamed Apple Music song outside the library, a player that isn't
    /// running), its title and artist go to the clipboard instead.
    func playRecentTrack(_ track: RecentTrack) {
        Task {
            if await music.play(track) {
                refreshSoon()
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(track.displayText, forType: .string)
            showPopupNotice(NSLocalizedString("Copied title and artist", comment: ""))
            hoverPopup.present(relativeTo: statusItem.button)
        }
    }

    // MARK: - Accessibility

    private func updateAccessibility() {
        let label: String
        if !music.permissionDeniedPlayers.isEmpty, !model.hasTrack {
            label = NSLocalizedString("MusicBar needs permission to control the player", comment: "")
        } else if !model.hasTrack {
            label = NSLocalizedString("No music playing", comment: "")
        } else if model.isPlaying {
            label = String(format: NSLocalizedString("Playing %@", comment: ""), model.displayText)
        } else {
            label = String(format: NSLocalizedString("Paused %@", comment: ""), model.displayText)
        }
        statusItem.button?.setAccessibilityLabel(label)
    }

    // MARK: - Updates

    /// The automatic check: silent, at most daily, and only if enabled. A
    /// find shows up as a menu item rather than interrupting.
    private func checkForUpdatesIfDue() {
        guard AppSettings.shared.checkForUpdatesAutomatically, UpdateChecker.isAutomaticCheckDue() else { return }
        Task {
            if let version = try? await UpdateChecker.availableUpdate() {
                availableUpdate = version
            }
        }
    }
}
