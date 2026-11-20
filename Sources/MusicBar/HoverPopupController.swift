import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// What the card's buttons do; the status item controller owns the logic.
@MainActor
struct PopupActions {
    var playPause: @MainActor () -> Void
    var previous: @MainActor () -> Void
    var next: @MainActor () -> Void
    var toggleFavorite: @MainActor () -> Void
    var addToPlaylist: @MainActor (Playlist) -> Void
    var seek: @MainActor (TimeInterval) -> Void
    /// Absolute volume, 0...100, from the card's slider.
    var setVolume: @MainActor (Int) -> Void
    /// Relative volume step, from the keyboard.
    var changeVolume: @MainActor (Int) -> Void
    var toggleShuffle: @MainActor () -> Void
    var cycleRepeat: @MainActor () -> Void
    var selectOutput: @MainActor (OutputDevice) -> Void
}

/// The card's window. It never takes the keyboard from the app in front
/// when shown by hovering; only a card opened with the shortcut becomes
/// key, so its controls can be worked without the pointer.
private final class CardPanel: NSPanel {
    var allowsKey = false
    var onKeyDown: ((NSEvent) -> Bool)?
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { allowsKey }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// Floating "now playing" card shown under the status item while the mouse
/// hovers it. The pointer can move onto the card to use its controls; the
/// card hides once the pointer has left both. Opened with the keyboard
/// shortcut instead, it takes key presses: Space plays or pauses, ← and →
/// change track, ↑ and ↓ the volume, F favorites, S shuffles, R repeats,
/// and Esc closes it.
@MainActor
final class HoverPopupController {
    private var panel: CardPanel?
    private var showTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private let model: TrackModel
    private let actions: PopupActions
    private let onWillShow: () -> Void
    private lazy var hostingView: HoverTrackingHostingView<HoverPopupView> = {
        let view = HoverTrackingHostingView(rootView: HoverPopupView(model: model, actions: actions))
        view.onHoverChange = { [weak self] hovering in
            if hovering { self?.hideTask?.cancel() } else { self?.scheduleHideCheck() }
        }
        return view
    }()
    private weak var anchorButton: NSStatusBarButton?
    private var cancellables: Set<AnyCancellable> = []
    /// A menu (e.g. the card's playlist menu) is open; keep the card up.
    private var isMenuTracking = false
    /// Opened from the keyboard: stay up until then regardless of the pointer.
    private var pinnedUntil: Date?
    private var pinTask: Task<Void, Never>?

    var isShown: Bool { panel?.isVisible ?? false }

    init(model: TrackModel, actions: PopupActions, onWillShow: @escaping () -> Void = {}) {
        self.model = model
        self.actions = actions
        self.onWillShow = onWillShow
        // objectWillChange fires before the new value lands; hop a run loop
        // turn so the relayout measures the updated content.
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.relayoutIfVisible() }
            }
            .store(in: &cancellables)
        // Menu tracking notifications arrive on the main thread, inside the
        // tracking run loop mode, so no scheduler hop here.
        NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.isMenuTracking = true }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isMenuTracking = false
                    self?.scheduleHideCheck()
                }
            }
            .store(in: &cancellables)
    }

    /// Called from the status item's hover tracking. A short delay before
    /// showing avoids flashing the panel when the mouse just passes by.
    func setHovering(_ hovering: Bool, relativeTo button: NSStatusBarButton?) {
        showTask?.cancel()
        showTask = nil

        guard hovering else { return scheduleHideCheck() }
        hideTask?.cancel()
        guard !isShown, model.hasTrack else { return }
        // Start loading the card's details during the show delay.
        onWillShow()

        showTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.model.hasTrack else { return }
            self.show(relativeTo: button)
        }
    }

    /// Hides right away, e.g. when the status item itself is clicked.
    func dismiss() {
        showTask?.cancel()
        hideTask?.cancel()
        pinTask?.cancel()
        pinnedUntil = nil
        hide()
    }

    /// Opens the card without hovering, e.g. from a keyboard shortcut. It
    /// stays up at least `seconds` (and while a notice shows), then follows
    /// the usual pointer rules. `takingKeyboard` also sends it key presses.
    func present(
        relativeTo button: NSStatusBarButton?,
        pinnedFor seconds: TimeInterval = 0,
        takingKeyboard: Bool = false
    ) {
        guard model.hasTrack else { return }
        showTask?.cancel()
        hideTask?.cancel()
        pin(for: seconds)
        if !isShown {
            onWillShow()
            show(relativeTo: button)
        }
        if takingKeyboard, let panel, panel.isVisible {
            panel.allowsKey = true
            panel.makeKey()
        }
    }

    func togglePresented(relativeTo button: NSStatusBarButton?) {
        if isShown {
            dismiss()
        } else {
            present(relativeTo: button, pinnedFor: Self.keyboardPin, takingKeyboard: true)
        }
    }

    /// How long a keyboard-opened card waits for the next key press.
    private static let keyboardPin: TimeInterval = 5

    /// Keeps the card up for `seconds` whatever the pointer does; 0 unpins.
    private func pin(for seconds: TimeInterval) {
        pinTask?.cancel()
        pinnedUntil = nil
        guard seconds > 0 else { return }
        pinnedUntil = Date().addingTimeInterval(seconds)
        pinTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.pinnedUntil = nil
            self.scheduleHideCheck()
        }
    }

    /// Key presses for a card opened from the keyboard. Returns false for
    /// keys it has no use for, so they aren't swallowed.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch Int(event.keyCode) {
        case kVK_Escape:
            dismiss()
            return true
        case kVK_Space: actions.playPause()
        case kVK_LeftArrow: actions.previous()
        case kVK_RightArrow: actions.next()
        case kVK_UpArrow: actions.changeVolume(5)
        case kVK_DownArrow: actions.changeVolume(-5)
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f" where model.isFavorited != nil: actions.toggleFavorite()
            case "s": actions.toggleShuffle()
            case "r": actions.cycleRepeat()
            default: return false
            }
        }
        // Each key press buys the card more time.
        pin(for: Self.keyboardPin)
        return true
    }

    private func show(relativeTo button: NSStatusBarButton?) {
        guard let button, button.window != nil else { return }
        anchorButton = button

        let panel = self.panel ?? makePanel()
        self.panel = panel

        // Gentle fade + downward drift in.
        guard let origin = layout(panel, under: button), !panel.isVisible else { return }
        panel.alphaValue = 0
        panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y + 6))
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(origin)
        }
    }

    private func relayoutIfVisible() {
        guard let panel, panel.isVisible, let anchorButton else { return }
        guard model.hasTrack else { return hide() }
        // The item's width follows the title, so re-centering on a track
        // change would slide the open card sideways.
        layout(panel, under: anchorButton, keepingHorizontalPosition: true)
        scheduleHideCheck()
    }

    /// Sizes the panel to its content and places it under the status item.
    @discardableResult
    private func layout(
        _ panel: NSPanel,
        under button: NSStatusBarButton,
        keepingHorizontalPosition: Bool = false
    ) -> NSPoint? {
        guard let buttonWindow = button.window else { return nil }
        let fittingSize = hostingView.fittingSize
        hostingView.frame.size = fittingSize
        panel.setContentSize(fittingSize)

        // Centered under the status item, just below the menu bar.
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var origin = NSPoint(
            x: buttonFrame.midX - panel.frame.width / 2,
            y: buttonFrame.minY - panel.frame.height - 6
        )
        if keepingHorizontalPosition {
            origin.x = panel.frame.minX
        } else if let screen = buttonWindow.screen {
            origin.x = min(max(origin.x, screen.visibleFrame.minX + 4), screen.visibleFrame.maxX - panel.frame.width - 4)
        }
        panel.setFrameOrigin(origin)
        return origin
    }

    /// Hides after a grace period long enough for the pointer to cross the
    /// gap between the status item and the card, unless by then it is back
    /// over either of them, a menu is open, or a notice is showing.
    private func scheduleHideCheck() {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled,
                  !self.isMenuTracking,
                  self.pinnedUntil == nil,
                  self.model.popupNotice == nil,
                  !self.pointerIsInside()
            else { return }
            self.hide()
        }
    }

    private func pointerIsInside() -> Bool {
        guard let panel, panel.isVisible else { return false }
        var area = panel.frame
        if let button = anchorButton, let window = button.window {
            area = area.union(window.convertToScreen(button.convert(button.bounds, to: nil)))
        }
        return area.contains(NSEvent.mouseLocation)
    }

    private func hide() {
        panel?.allowsKey = false
        panel?.orderOut(nil)
        // Drops the timer-driven progress views while nobody can see them.
        if model.progress != nil { model.progress = nil }
    }

    private func makePanel() -> CardPanel {
        let panel = CardPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hostingView
        panel.onKeyDown = { [weak self] event in self?.handleKeyDown(event) ?? false }
        // Clicking elsewhere ends keyboard mode; the pointer rules decide
        // from there.
        panel.onResignKey = { [weak self] in
            guard let self else { return }
            self.panel?.allowsKey = false
            self.pin(for: 0)
            self.scheduleHideCheck()
        }
        return panel
    }
}

/// Popup content: large cover art with the title and artist centered below,
/// like a compact "now playing" card.
struct HoverPopupView: View {
    @ObservedObject var model: TrackModel
    let actions: PopupActions

    private let coverSize: CGFloat = 168

    private var coverImage: NSImage? { model.artworkLarge ?? model.artwork }

    /// Where along the progress bar a click or drag at `x` lands, 0...1.
    static func seekFraction(x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1))
    }

    var body: some View {
        VStack(spacing: 12) {
            cover
                .frame(width: coverSize, height: coverSize)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    // Hairline edge so light covers don't melt into the card.
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.35), radius: 10, y: 5)

            VStack(spacing: 3) {
                // One line each keeps the card's height fixed; the tooltip
                // has the rest of a long title.
                Text(model.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .help(model.title)
                // Always laid out so a missing artist doesn't shrink the card.
                Text(model.artistAndAlbum.isEmpty ? " " : model.artistAndAlbum)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(model.artistAndAlbum)
            }
            .multilineTextAlignment(.center)
            .frame(width: coverSize)

            ProgressRow(progress: model.progress, isPlaying: model.isPlaying, notice: model.popupNotice, onSeek: actions.seek)
                .frame(width: coverSize)

            VStack(spacing: 2) {
                ControlsRow(model: model, actions: actions)
                UtilityRow(model: model, actions: actions)
            }
            .frame(width: coverSize)
            // Pointer-only card: a clicked button shouldn't keep a focus ring.
            .focusEffectDisabled()
        }
        .padding(16)
        .background {
            ZStack {
                // Blurred cover tints the card with the album's own colors.
                if let artwork = model.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 40)
                        .opacity(0.35)
                }
                Rectangle().fill(.regularMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let artwork = coverImage {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
        }
    }
}

/// Thin bar with elapsed and total time, or a notice in place of the times.
/// Always takes the same space so the card never changes height: with no
/// position (radio, or before it loads) the bar is hidden, not removed.
/// While playing, the timer-interval views advance on their own. Click or
/// drag along the bar to seek; the song jumps when the drag ends.
private struct ProgressRow: View {
    let progress: PlaybackProgress?
    let isPlaying: Bool
    let notice: String?
    let onSeek: @MainActor (TimeInterval) -> Void

    /// Position under the pointer during a drag, 0...1.
    @State private var dragFraction: Double?

    var body: some View {
        VStack(spacing: 3) {
            // Taller than the bar itself so it's an easy click target.
            GeometryReader { geometry in
                bar
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in
                                guard progress != nil else { return }
                                dragFraction = HoverPopupView.seekFraction(x: value.location.x, width: geometry.size.width)
                            }
                            .onEnded { value in
                                dragFraction = nil
                                guard let progress else { return }
                                let fraction = HoverPopupView.seekFraction(x: value.location.x, width: geometry.size.width)
                                onSeek(fraction * progress.duration)
                            }
                    )
            }
            .frame(height: 12)
            .opacity(progress == nil ? 0 : 1)
            ZStack {
                // Reserves one line of height whatever is shown.
                Text(verbatim: "0:00").hidden()
                if let notice {
                    Text(notice)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                } else if let progress {
                    HStack {
                        if let dragFraction {
                            Text(Self.format(dragFraction * progress.duration))
                        } else if isPlaying {
                            Text(timerInterval: progress.start...progress.end, countsDown: false)
                        } else {
                            Text(Self.format(progress.position))
                        }
                        Spacer()
                        Text(Self.format(progress.duration))
                    }
                }
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .progressViewStyle(.linear)
        .controlSize(.small)
    }

    @ViewBuilder
    private var bar: some View {
        if let progress, let dragFraction {
            ProgressView(value: dragFraction * progress.duration, total: progress.duration)
        } else if let progress, isPlaying {
            ProgressView(timerInterval: progress.start...progress.end, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
        } else {
            ProgressView(value: progress?.position ?? 0, total: progress?.duration ?? 1)
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}

/// Transport controls. The fixed-width side slots keep the transport centered
/// whether or not the player supports the library actions.
private struct ControlsRow: View {
    @ObservedObject var model: TrackModel
    let actions: PopupActions

    var body: some View {
        HStack(spacing: 0) {
            if let isFavorited = model.isFavorited {
                ControlButton(
                    title: isFavorited ? "Remove from Favorites" : "Favorite",
                    systemImage: isFavorited ? "heart.fill" : "heart",
                    action: actions.toggleFavorite
                )
                .foregroundStyle(isFavorited ? AnyShapeStyle(.pink) : AnyShapeStyle(.secondary))
            } else {
                Self.emptySlot
            }
            Spacer(minLength: 0)
            ControlButton(title: "Previous Track", systemImage: "backward.fill", action: actions.previous)
            ControlButton(
                title: model.isPlaying ? "Pause" : "Play",
                systemImage: model.isPlaying ? "pause.fill" : "play.fill",
                size: 20,
                action: actions.playPause
            )
            ControlButton(title: "Next Track", systemImage: "forward.fill", action: actions.next)
            Spacer(minLength: 0)
            if model.playlists.isEmpty {
                Self.emptySlot
            } else {
                playlistMenu
            }
        }
    }

    private var playlistMenu: some View {
        Menu {
            ForEach(model.playlists) { playlist in
                Button(playlist.name) { actions.addToPlaylist(playlist) }
            }
        } label: {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 13, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 33, height: 30)
        .help(Text("Add to Playlist"))
        .accessibilityLabel(Text("Add to Playlist"))
    }

    /// Same footprint as a 13 pt ControlButton.
    private static var emptySlot: some View { Color.clear.frame(width: 33, height: 30) }
}

/// Secondary controls under the transport. Always laid out, even before the
/// modes load, so the card keeps its height.
private struct UtilityRow: View {
    @ObservedObject var model: TrackModel
    let actions: PopupActions

    var body: some View {
        HStack(spacing: 0) {
            if let modes = model.playbackModes {
                ControlButton(
                    title: "Shuffle",
                    systemImage: "shuffle",
                    size: 11,
                    height: 22,
                    isOn: modes.shuffle,
                    action: actions.toggleShuffle
                )
                ControlButton(
                    title: "Repeat",
                    systemImage: modes.repeatMode == .one ? "repeat.1" : "repeat",
                    size: 11,
                    height: 22,
                    isOn: modes.repeatMode != .off,
                    action: actions.cycleRepeat
                )
            }
            if let volume = model.volume {
                Slider(
                    value: Binding(
                        get: { Double(volume) },
                        set: { actions.setVolume(Int($0.rounded())) }
                    ),
                    in: 0...100
                )
                .controlSize(.mini)
                .padding(.horizontal, 6)
                .help(Text("Volume"))
                .accessibilityLabel(Text("Volume"))
            } else {
                Spacer(minLength: 0)
            }
            // Only worth a menu when there's somewhere else to play.
            if model.outputDevices.count > 1 {
                outputMenu
            }
        }
        .frame(height: 22)
    }

    private var outputMenu: some View {
        Menu {
            ForEach(model.outputDevices) { device in
                Toggle(device.name, isOn: Binding(
                    get: { device.isSelected },
                    set: { _ in actions.selectOutput(device) }
                ))
            }
        } label: {
            Image(systemName: "airplayaudio")
                .font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 31, height: 22)
        .foregroundStyle(.secondary)
        .help(Text("Output"))
        .accessibilityLabel(Text("Output"))
    }
}

private struct ControlButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var size: CGFloat = 13
    var height: CGFloat = 30
    /// Toggles tint when on and dim when off; plain buttons leave it nil.
    var isOn: Bool?
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size + 20, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .help(Text(title))
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isOn == true ? .isSelected : [])
    }

    private var tint: AnyShapeStyle {
        switch isOn {
        case true?: AnyShapeStyle(.tint)
        case false?: AnyShapeStyle(.secondary)
        case nil: AnyShapeStyle(.primary)
        }
    }
}
