import AppKit
import SwiftUI

/// Floating panel shown under the status item while the mouse hovers it:
/// album cover plus song title and artist. Never takes focus or clicks.
@MainActor
final class HoverPopupController {
    private var panel: NSPanel?
    private var showTask: Task<Void, Never>?
    private let model: TrackModel
    private let onWillShow: () -> Void
    private lazy var hostingView = NSHostingView(rootView: HoverPopupView(model: model))

    init(model: TrackModel, onWillShow: @escaping () -> Void = {}) {
        self.model = model
        self.onWillShow = onWillShow
    }

    /// Called from the status item's hover tracking. A short delay before
    /// showing avoids flashing the panel when the mouse just passes by.
    func setHovering(_ hovering: Bool, relativeTo button: NSStatusBarButton?) {
        showTask?.cancel()
        showTask = nil

        guard hovering else {
            hide()
            return
        }
        guard model.hasTrack else { return }

        showTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.model.hasTrack else { return }
            self.show(relativeTo: button)
        }
    }

    private func show(relativeTo button: NSStatusBarButton?) {
        guard let button, let buttonWindow = button.window else { return }
        onWillShow()

        let panel = self.panel ?? makePanel()
        self.panel = panel

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

        // Gentle fade + downward drift in.
        guard !panel.isVisible else { return }
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

    private func hide() {
        panel?.orderOut(nil)
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
        panel.ignoresMouseEvents = true
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
