import AppKit

/// What the hover card shows and what its controls do.
extension StatusItemController {
    // MARK: - Card

    /// Everything the card shows beyond the track itself. Fetched as soon as
    /// the pointer lands on the item, so it's usually ready before the card
    /// appears, and again when the player reports a change while it's open.
    /// Each piece is published as it arrives; the playlist listing (the
    /// slowest script) comes last and is only re-read when the card opens.
    func loadPopupDetails(includePlaylists: Bool) {
        progressTask?.cancel()
        progressTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let progress = await self.music.fetchProgress()
            guard !Task.isCancelled, self.popupWanted else { return }
            self.model.progress = progress

            let favorited = await self.music.fetchFavorited()
            guard !Task.isCancelled, self.popupWanted else { return }
            if self.model.isFavorited != favorited { self.model.isFavorited = favorited }

            let rating = await self.music.fetchRating()
            guard !Task.isCancelled, self.popupWanted else { return }
            if self.model.rating != rating { self.model.rating = rating }

            let modes = await self.music.fetchPlaybackModes()
            guard !Task.isCancelled, self.popupWanted else { return }
            if self.model.playbackModes != modes { self.model.playbackModes = modes }

            let volume = await self.music.fetchVolume()
            guard !Task.isCancelled, self.popupWanted else { return }
            // A slider being dragged knows better than a reading taken
            // before the drag.
            if self.volumeTask == nil, self.model.volume != volume { self.model.volume = volume }

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
    var popupWanted: Bool { hoverPopup.isShown || model.isHovering }

    func addCurrentTrack(to playlist: Playlist, presentingCard: Bool = false) {
        Task {
            defer { if presentingCard { hoverPopup.present(relativeTo: statusItem.button) } }
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
    func showPopupNotice(_ text: String) {
        noticeTask?.cancel()
        model.popupNotice = text
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.model.popupNotice = nil
        }
    }

    /// Optimistic; restores the list and says so if Music refuses.
    func selectOutput(_ device: OutputDevice) {
        let previous = model.outputDevices
        model.outputDevices = previous.map { OutputDevice(id: $0.id, name: $0.name, isSelected: $0.id == device.id) }
        Task {
            guard !(await music.selectOutput(device)) else { return }
            model.outputDevices = previous
            showPopupNotice(String(format: NSLocalizedString("Couldn't switch to %@", comment: ""), device.name))
        }
    }

    func toggleShuffle() {
        guard var modes = model.playbackModes else { return }
        modes.shuffle.toggle()
        model.playbackModes = modes
        music.setShuffle(modes.shuffle)
    }

    /// Off → all → one (Music only) → off.
    func cycleRepeat() {
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
    func seek(to position: TimeInterval) {
        music.seek(to: position)
        loadMenuBarProgress()
        guard let progress = model.progress else { return }
        model.progress = PlaybackProgress(
            position: position,
            duration: progress.duration,
            start: Date().addingTimeInterval(-position)
        )
    }

    /// Optimistic: flips the heart at once and reverts if Music refuses.
    /// Only for a known state; see `toggleFavoriteReadingState`.
    func toggleFavorite() {
        let favorited = !(model.isFavorited ?? false)
        let key = currentTrackKey
        model.isFavorited = favorited
        Task {
            guard !(await music.setFavorited(favorited)), currentTrackKey == key else { return }
            model.isFavorited = !favorited
        }
    }

    /// For the menu and the shortcut, where the heart's state may not be
    /// loaded yet: read it before flipping, so an already-favorited song is
    /// unfavorited rather than favorited again. Then show the result.
    func toggleFavoriteReadingState() {
        guard model.hasTrack else { return }
        Task {
            guard let current = await music.fetchFavorited() else { return }
            model.isFavorited = current
            toggleFavorite()
            showPopupNotice(current
                ? NSLocalizedString("Removed from Favorites", comment: "")
                : NSLocalizedString("Added to Favorites", comment: ""))
            hoverPopup.present(relativeTo: statusItem.button)
        }
    }

    /// Rates the song 0...5 stars and shows the result in the card.
    func rate(stars: Int) {
        let key = currentTrackKey
        Task {
            guard await music.setRating(stars: stars) else {
                showPopupNotice(NSLocalizedString("Couldn't rate this song", comment: ""))
                hoverPopup.present(relativeTo: statusItem.button)
                return
            }
            if currentTrackKey == key {
                model.rating = TrackRating(stars: stars, isDisliked: model.rating?.isDisliked)
            }
            showPopupNotice(stars == 0
                ? NSLocalizedString("Rating removed", comment: "")
                : String(repeating: "★", count: stars))
            hoverPopup.present(relativeTo: statusItem.button)
        }
    }

    func toggleDislike() {
        let key = currentTrackKey
        Task {
            // Read first: the menu may have been built without the state.
            let disliked = !((await music.fetchRating())?.isDisliked ?? false)
            guard await music.setDisliked(disliked) else {
                showPopupNotice(NSLocalizedString("Couldn't rate this song", comment: ""))
                hoverPopup.present(relativeTo: statusItem.button)
                return
            }
            if currentTrackKey == key {
                model.rating = TrackRating(stars: model.rating?.stars ?? 0, isDisliked: disliked)
            }
            showPopupNotice(disliked
                ? NSLocalizedString("Marked as disliked", comment: "")
                : NSLocalizedString("No longer disliked", comment: ""))
            hoverPopup.present(relativeTo: statusItem.button)
        }
    }

    // MARK: - Volume

    /// Relative steps from the scroll wheel and the keyboard. Steps that
    /// arrive while a script is in flight add up into the next one, so a
    /// long scroll doesn't queue a script per notch.
    func changeVolume(by delta: Int) {
        pendingVolumeDelta += delta
        startVolumeTaskIfNeeded()
    }

    /// Absolute value from the card's slider; only the latest matters.
    func setVolume(_ volume: Int) {
        model.volume = volume
        pendingVolume = volume
        pendingVolumeDelta = 0
        startVolumeTaskIfNeeded()
    }

    func startVolumeTaskIfNeeded() {
        guard volumeTask == nil else { return }
        volumeTask = Task { @MainActor [weak self] in
            while let self, self.pendingVolume != nil || self.pendingVolumeDelta != 0 {
                if let volume = self.pendingVolume {
                    self.pendingVolume = nil
                    await self.music.setVolume(volume)
                } else {
                    let delta = self.pendingVolumeDelta
                    self.pendingVolumeDelta = 0
                    guard let volume = await self.music.changeVolume(by: delta) else { continue }
                    self.model.volume = volume
                    // The card is usually open while the pointer is over the item.
                    self.showPopupNotice(String(format: NSLocalizedString("Volume %d%%", comment: ""), volume))
                }
            }
            self?.volumeTask = nil
        }
    }
}
