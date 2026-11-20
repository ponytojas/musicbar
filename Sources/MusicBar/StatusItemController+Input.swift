import AppKit

/// Clicks, scrolling, and keyboard shortcuts on the menu bar item.
extension StatusItemController {
    // MARK: - Keyboard shortcuts

    func registerHotKeys() {
        let settings = AppSettings.shared
        let active = settings.globalShortcuts && settings.recordingShortcut == nil
        let unavailable = hotKeys.register(active ? settings.shortcuts : [:])
        // While recording nothing is registered, so nothing is known to
        // be taken; keep the last verdict on screen.
        if active || !settings.globalShortcuts, settings.unavailableShortcuts != unavailable {
            settings.unavailableShortcuts = unavailable
        }
    }

    func handleHotKey(_ action: HotKeyAction) {
        switch action {
        case .toggleCard: hoverPopup.togglePresented(relativeTo: statusItem.button)
        case .toggleFavorite: toggleFavoriteReadingState()
        case .addToPlaylist: showPlaylistMenuFromKeyboard()
        case .playPause: togglePlayback()
        case .nextTrack: skip(forward: true)
        case .previousTrack: skip(forward: false)
        case .volumeUp: changeVolume(by: 5)
        case .volumeDown: changeVolume(by: -5)
        case .seekForward: seek(by: HotKeyAction.seekSeconds)
        case .seekBackward: seek(by: -HotKeyAction.seekSeconds)
        }
    }

    /// Jumps within the song. The scripts run in order, so an open card
    /// reads the position after the jump.
    func seek(by seconds: Int) {
        guard model.hasTrack else { return }
        music.seek(by: seconds)
        if hoverPopup.isShown { loadPopupDetails(includePlaylists: false) }
    }

    func showPlaylistMenuFromKeyboard() {
        guard model.hasTrack, music.activePlayer == .appleMusic else { return }
        Task {
            let playlists = await music.fetchPlaylists()
            guard !playlists.isEmpty, let button = statusItem.button else { return }
            let menu = NSMenu()
            // No action, so it shows as a disabled header.
            menu.addItem(NSMenuItem(title: NSLocalizedString("Add to Playlist", comment: ""), action: nil, keyEquivalent: ""))
            for playlist in playlists {
                let item = NSMenuItem(title: playlist.name, action: #selector(addToPlaylistFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = playlist
                menu.addItem(item)
            }
            // Activate so the menu takes arrow keys and Return.
            NSApp.activate()
            let below = NSPoint(x: 0, y: button.isFlipped ? button.bounds.maxY + 4 : -4)
            _ = menu.popUp(positioning: nil, at: below, in: button)
        }
    }

    @objc func addToPlaylistFromMenu(_ sender: NSMenuItem) {
        guard let playlist = sender.representedObject as? Playlist else { return }
        addCurrentTrack(to: playlist, presentingCard: true)
    }

    // MARK: - Clicks

    func togglePlayback() {
        music.playPause()
        refreshSoon()
    }

    func skip(forward: Bool) {
        if forward { music.nextTrack() } else { music.previousTrack() }
        refreshSoon()
    }

    @objc func handleClick() {
        // Don't leave the popup floating over a menu or while interacting.
        hoverPopup.dismiss()

        // VoiceOver and keyboard activation arrive without a mouse event,
        // and asking a key event for its click count raises an exception.
        guard let event = NSApp.currentEvent,
              [.leftMouseUp, .rightMouseUp].contains(event.type)
        else {
            togglePlayback()
            return
        }

        // Control-click is the other way to ask for a context menu.
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
            return
        }

        // Option-click skips to the next track, Shift-click goes back one;
        // neither waits for a possible double click.
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.shift) {
            singleClickTimer?.invalidate()
            singleClickTimer = nil
            skip(forward: event.modifierFlags.contains(.option))
            return
        }

        // Without the double-click action there is nothing to wait for, so
        // every click answers at once.
        guard AppSettings.shared.doubleClickOpensPlayer else {
            togglePlayback()
            return
        }

        switch event.clickCount {
        case 1:
            // Delay so a second click can cancel the play/pause.
            singleClickTimer = Timer.scheduledTimer(
                withTimeInterval: NSEvent.doubleClickInterval,
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor in self?.togglePlayback() }
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
    func observeScrollWheel() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleScroll(event) ?? false }
            return handled ? nil : event
        }
    }

    func handleScroll(_ event: NSEvent) -> Bool {
        guard event.window === statusItem.button?.window, AppSettings.shared.scrollChangesVolume else { return false }
        // A trackpad flick keeps sending events after the fingers lift;
        // the volume should stop when they do.
        guard event.momentumPhase.isEmpty else { return true }
        // Physical direction regardless of natural scrolling: up is louder.
        var delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        // Trackpads report points; scale them down to wheel-like steps.
        if event.hasPreciseScrollingDeltas { delta /= 8 }
        scrollAccumulator += delta
        let steps = Int(scrollAccumulator)
        guard steps != 0 else { return true }
        scrollAccumulator -= CGFloat(steps)
        changeVolume(by: steps * 5)
        return true
    }

    /// Give the player a moment to apply the command before reconciling.
    /// Fallback only — cancelled if the player's notification arrives first.
    func refreshSoon() {
        pendingReconcile?.cancel()
        pendingReconcile = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }
}
