import AppKit

/// The right-click menu and what its items do.
extension StatusItemController {
    func showContextMenu() {
        let menu = NSMenu()
        addAttentionItems(to: menu)

        let openTitle = music.activePlayer == .spotify
            ? NSLocalizedString("Open Spotify", comment: "")
            : NSLocalizedString("Open Music", comment: "")
        menu.addItem(item(openTitle, #selector(openPlayer)))
        if model.hasTrack, music.activePlayer == .appleMusic {
            let favoriteItem = item(NSLocalizedString("Favorite Song", comment: ""), #selector(favoriteSong))
            favoriteItem.state = model.isFavorited == true ? .on : .off
            menu.addItem(favoriteItem)
            menu.addItem(item(NSLocalizedString("Show in Music", comment: ""), #selector(showInMusic)))
        }
        if model.hasTrack, music.activePlayer == .spotify {
            menu.addItem(item(NSLocalizedString("Copy Song Link", comment: ""), #selector(copySongLink)))
        }
        if let recentItem = recentTracksMenuItem() {
            menu.addItem(recentItem)
        }
        menu.addItem(.separator())
        menu.addItem(sleepTimerMenuItem())
        menu.addItem(.separator())
        let updateTitle = availableUpdate.map {
            String(format: NSLocalizedString("Update Available: %@…", comment: ""), $0)
        } ?? NSLocalizedString("Check for Updates…", comment: "")
        menu.addItem(item(updateTitle, #selector(checkForUpdates)))
        menu.addItem(item(NSLocalizedString("Settings…", comment: ""), #selector(openSettings), key: ","))
        menu.addItem(item(NSLocalizedString("Tips…", comment: ""), #selector(showTips)))
        menu.addItem(item(NSLocalizedString("About MusicBar", comment: ""), #selector(showAbout)))
        menu.addItem(.separator())
        menu.addItem(item(NSLocalizedString("Quit MusicBar", comment: ""), #selector(quit), key: "q"))

        // Assign temporarily so left clicks keep their custom behavior.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// Problems only the user can fix go first: with a permission missing
    /// the item shows a bare note and nothing else says why.
    private func addAttentionItems(to menu: NSMenu) {
        var added = false
        for player in PlayerApp.allCases where music.permissionDeniedPlayers.contains(player) {
            let title = String(
                format: NSLocalizedString("Allow MusicBar to Control %@…", comment: ""),
                player.scriptName
            )
            menu.addItem(item(title, #selector(openAutomationSettings)))
            added = true
        }
        if captureFailed {
            menu.addItem(item(NSLocalizedString("Equalizer Is Simulated…", comment: ""), #selector(explainSimulatedEqualizer)))
            added = true
        }
        if added { menu.addItem(.separator()) }
    }

    private func recentTracksMenuItem() -> NSMenuItem? {
        // The current song is already in the menu bar.
        let current = RecentTrack(title: model.title, artist: model.artist)
        let history = recentTracks.filter { !$0.isSameSong(as: current) }
        guard !history.isEmpty else { return nil }
        let recentItem = NSMenuItem(title: NSLocalizedString("Recently Played", comment: ""), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for track in history {
            let trackItem = item(track.displayText, #selector(playRecent(_:)))
            trackItem.representedObject = track
            trackItem.toolTip = track.trackID == nil
                ? NSLocalizedString("Copy title and artist", comment: "")
                : NSLocalizedString("Play again", comment: "")
            submenu.addItem(trackItem)
        }
        submenu.addItem(.separator())
        submenu.addItem(item(NSLocalizedString("Clear Recently Played", comment: ""), #selector(clearRecents)))
        recentItem.submenu = submenu
        return recentItem
    }

    private func sleepTimerMenuItem() -> NSMenuItem {
        let timerItem = NSMenuItem(title: NSLocalizedString("Sleep Timer", comment: ""), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if let end = sleepTimer.end {
            // No action, so the menu shows it disabled.
            submenu.addItem(NSMenuItem(
                title: String(format: NSLocalizedString("Pauses at %@", comment: ""), end.formatted(date: .omitted, time: .shortened)),
                action: nil,
                keyEquivalent: ""
            ))
            submenu.addItem(.separator())
        }
        let modes: [(SleepTimer.Mode, String)] = [
            (.off, NSLocalizedString("Off", comment: "")),
        ] + [15, 30, 60].map {
            (.minutes($0), String(format: NSLocalizedString("%d minutes", comment: ""), $0))
        } + [
            (.endOfTrack, NSLocalizedString("When the Song Ends", comment: "")),
        ]
        for (mode, title) in modes {
            let option = item(title, #selector(setSleepTimer(_:)))
            option.tag = Self.tag(for: mode)
            option.state = sleepTimer.mode == mode ? .on : .off
            submenu.addItem(option)
        }
        // A countdown that isn't one of the presets was typed in here.
        let customItem = item(NSLocalizedString("Custom…", comment: ""), #selector(setCustomSleepTimer))
        if case let .minutes(minutes) = sleepTimer.mode, ![15, 30, 60].contains(minutes) {
            customItem.state = .on
        }
        submenu.addItem(customItem)
        submenu.addItem(.separator())
        let fadeItem = item(NSLocalizedString("Fade Out Before Pausing", comment: ""), #selector(toggleSleepTimerFade))
        fadeItem.state = AppSettings.shared.sleepTimerFadeOut ? .on : .off
        submenu.addItem(fadeItem)
        timerItem.submenu = submenu
        return timerItem
    }

    @objc private func toggleSleepTimerFade() {
        AppSettings.shared.sleepTimerFadeOut.toggle()
    }

    @objc private func setCustomSleepTimer() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Pause after how many minutes?", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Start", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.placeholderString = "45"
        if case let .minutes(minutes) = sleepTimer.mode { field.stringValue = String(minutes) }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let minutes = SleepTimer.customMinutes(from: field.stringValue) else {
            NSSound.beep()
            return
        }
        sleepTimer.set(.minutes(minutes))
    }

    /// Menu items carry the mode as a tag: minutes, 0 for off, -1 for the
    /// end of the song.
    private static func tag(for mode: SleepTimer.Mode) -> Int {
        switch mode {
        case .off: 0
        case let .minutes(minutes): minutes
        case .endOfTrack: -1
        }
    }

    @objc private func setSleepTimer(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: sleepTimer.set(.off)
        case -1: sleepTimer.set(.endOfTrack)
        default: sleepTimer.set(.minutes(sender.tag))
        }
    }

    @objc private func playRecent(_ sender: NSMenuItem) {
        guard let track = sender.representedObject as? RecentTrack else { return }
        playRecentTrack(track)
    }

    @objc private func clearRecents() {
        clearRecentTracks()
    }

    @objc private func showInMusic() {
        music.revealCurrentTrack()
    }

    @objc private func favoriteSong() {
        toggleFavoriteReadingState()
    }

    @objc private func copySongLink() {
        Task {
            guard let url = await music.spotifyTrackLink() else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            showPopupNotice(NSLocalizedString("Link copied", comment: ""))
            hoverPopup.present(relativeTo: statusItem.button)
        }
    }

    @objc private func openPlayer() {
        music.openPlayerApp()
    }

    @objc private func openAutomationSettings() {
        AutomationPermission.openSystemSettings()
    }

    @objc private func explainSimulatedEqualizer() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("The equalizer is showing simulated movement", comment: "")
        alert.informativeText = NSLocalizedString(
            "MusicBar couldn't listen to the player's audio. Allow it under System Audio Recording Only in Privacy & Security, or choose the Simulated style in Settings to stop it trying.",
            comment: ""
        )
        alert.addButton(withTitle: NSLocalizedString("Open System Settings", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: ""))
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func checkForUpdates() {
        Task {
            let alert = NSAlert()
            var offersDownload = false
            do {
                if let version = try await UpdateChecker.availableUpdate() {
                    availableUpdate = version
                    offersDownload = true
                    alert.messageText = String(format: NSLocalizedString("MusicBar %@ is available", comment: ""), version)
                    alert.informativeText = String(
                        format: NSLocalizedString("You have version %@.", comment: ""),
                        UpdateChecker.currentVersion
                    )
                    alert.addButton(withTitle: NSLocalizedString("Open Download Page", comment: ""))
                    alert.addButton(withTitle: NSLocalizedString("Later", comment: ""))
                } else {
                    availableUpdate = nil
                    alert.messageText = NSLocalizedString("MusicBar is up to date", comment: "")
                    alert.informativeText = String(
                        format: NSLocalizedString("You have version %@.", comment: ""),
                        UpdateChecker.currentVersion
                    )
                }
            } catch {
                alert.messageText = NSLocalizedString("Couldn't check for updates", comment: "")
                alert.informativeText = error.localizedDescription
            }
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn, offersDownload {
                NSWorkspace.shared.open(UpdateChecker.releasePage)
            }
        }
    }

    @objc func openSettings() {
        settingsWindow.show()
    }

    @objc private func showTips() {
        welcomeWindow.show()
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
