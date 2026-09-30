import AppKit
import Combine
import SwiftUI

/// What the card's buttons do; the status item controller owns the logic.
@MainActor
struct PopupActions {
    var playPause: @MainActor () -> Void
    var previous: @MainActor () -> Void
    var next: @MainActor () -> Void
}

/// Floating "now playing" card shown under the status item while the mouse
/// hovers it. The pointer can move onto the card to use its controls; the
/// card hides once the pointer has left both. Never takes focus.
@MainActor
final class HoverPopupController {
    private var panel: NSPanel?
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
        hide()
    }

    private func show(relativeTo button: NSStatusBarButton?) {
        guard let button, button.window != nil else { return }
        onWillShow()
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
        layout(panel, under: anchorButton)
        scheduleHideCheck()
    }

    /// Sizes the panel to its content and places it under the status item.
    @discardableResult
    private func layout(_ panel: NSPanel, under button: NSStatusBarButton) -> NSPoint? {
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
        if let screen = buttonWindow.screen {
            origin.x = min(max(origin.x, screen.visibleFrame.minX + 4), screen.visibleFrame.maxX - panel.frame.width - 4)
        }
        panel.setFrameOrigin(origin)
        return origin
    }

    /// Hides after a grace period long enough for the pointer to cross the
    /// gap between the status item and the card, unless by then it is back
    /// over either of them or a menu is open.
    private func scheduleHideCheck() {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled,
                  !self.isMenuTracking,
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
        panel?.orderOut(nil)
        // Drops the timer-driven progress views while nobody can see them.
        if model.progress != nil { model.progress = nil }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
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
                Text(model.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                if !model.artist.isEmpty {
                    Text(model.artist)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .multilineTextAlignment(.center)
            .frame(width: coverSize)

            if let progress = model.progress {
                ProgressRow(progress: progress, isPlaying: model.isPlaying)
                    .frame(width: coverSize)
            }

            ControlsRow(model: model, actions: actions)
                .frame(width: coverSize)
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

/// Thin bar with elapsed and total time. While playing, the timer-interval
/// views advance on their own from `progress.start`.
private struct ProgressRow: View {
    let progress: PlaybackProgress
    let isPlaying: Bool

    var body: some View {
        VStack(spacing: 3) {
            if isPlaying {
                ProgressView(timerInterval: progress.start...progress.end, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            } else {
                ProgressView(value: progress.position, total: progress.duration)
            }
            HStack {
                if isPlaying {
                    Text(timerInterval: progress.start...progress.end, countsDown: false)
                } else {
                    Text(Self.format(progress.position))
                }
                Spacer()
                Text(Self.format(progress.duration))
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .progressViewStyle(.linear)
        .controlSize(.small)
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
            Color.clear.frame(width: 30, height: 30)
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
            Color.clear.frame(width: 30, height: 30)
        }
    }
}

private struct ControlButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var size: CGFloat = 13
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size + 20, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(title))
        .accessibilityLabel(Text(title))
    }
}
