import SwiftUI

/// Content of the menu bar item: a state icon plus the track title in a
/// marquee.
struct StatusBarView: View {
    @ObservedObject var model: TrackModel
    let waveform: AudioWaveformModel
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var displayText: String {
        TitleFormat.render(settings.titleFormat, title: model.title, artist: model.artist, album: model.album)
    }

    private var showsTrack: Bool { model.hasTrack && !model.isCollapsed }

    private var showsCover: Bool { settings.showArtwork && showsTrack && model.artwork != nil }

    /// Nothing queued, or every part of the track display is off or
    /// missing: the note keeps the item from going blank.
    private var showsNote: Bool {
        !showsTrack || !(settings.showTitle || settings.showEqualizer || showsCover)
    }

    /// Reduce Motion swaps the slides and springs for a short fade.
    private var change: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4)
    }

    private var titleTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)
            )
    }

    var body: some View {
        HStack(spacing: 6) {
            if showsCover, let artwork = model.artwork {
                // ZStack keeps a single 17 pt slot while the old cover
                // animates out and the new one in (id swap = new identity).
                ZStack {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 17, height: 17)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .id(ObjectIdentifier(artwork))
                        .transition(.asymmetric(
                            insertion: reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
                .frame(width: 17, height: 17)
            }

            if showsNote {
                Image(systemName: "music.note")
                    .font(.system(size: 12, weight: .semibold))
            } else {
                if settings.showEqualizer && settings.equalizerPosition == .left {
                    equalizer
                }

                if settings.showTitle {
                    MarqueeText(
                        text: displayText,
                        maxWidth: settings.textWidth,
                        fontSize: settings.titleFontSize,
                        model: model,
                        settings: settings
                    )
                        .id(displayText)
                        .transition(titleTransition)
                }

                if settings.showEqualizer && settings.equalizerPosition == .right {
                    equalizer
                }
            }

            if model.sleepTimerActive {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 22)
        .clipped()
        .animation(change, value: displayText)
        .animation(change, value: model.isPlaying)
        .animation(change, value: model.isCollapsed)
        .animation(change, value: model.sleepTimerActive)
        .animation(change, value: model.artwork.map(ObjectIdentifier.init))
        .animation(change, value: settings.showArtwork)
        .animation(change, value: settings.showEqualizer)
        .animation(change, value: settings.showTitle)
        .animation(change, value: settings.fitTitleToContent)
        .animation(change, value: settings.textWidth)
        .animation(change, value: settings.titleFontSize)
        .animation(change, value: settings.equalizerPosition)
    }

    private var equalizer: some View {
        EqualizerView(
            waveform: waveform,
            isPlaying: model.isPlaying,
            artwork: model.artwork,
            colorMode: settings.equalizerColorMode,
            customColor: settings.equalizerColor
        )
    }
}

/// Real audio waveform drawn by AppKit only when new level data arrives. This
/// deliberately avoids TimelineView/Canvas, which retained large graphics
/// surfaces when embedded in an NSStatusItem on macOS 26.
struct EqualizerView: View {
    let waveform: AudioWaveformModel
    let isPlaying: Bool
    let artwork: NSImage?
    var colorMode: EqualizerColorMode = .gradient
    var customColor: Color = .primary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        WaveformRepresentable(
            waveform: waveform,
            reducedMotion: reduceMotion,
            isPlaying: isPlaying,
            artwork: artwork,
            colorMode: colorMode,
            customColor: NSColor(customColor)
        )
        .frame(width: 16, height: 16)
    }
}

private struct WaveformRepresentable: NSViewRepresentable {
    let waveform: AudioWaveformModel
    let reducedMotion: Bool
    let isPlaying: Bool
    let artwork: NSImage?
    let colorMode: EqualizerColorMode
    let customColor: NSColor

    func makeNSView(context: Context) -> WaveformDrawingView {
        let view = WaveformDrawingView()
        waveform.connect(view)
        return view
    }

    func updateNSView(_ view: WaveformDrawingView, context: Context) {
        view.update(
            levels: reducedMotion
                ? [0.14, 0.46, 0.72, 0.32, 0.84, 0.52, 0.16]
                : waveform.levels,
            reducedMotion: reducedMotion,
            isPlaying: isPlaying,
            artwork: artwork,
            colorMode: colorMode,
            customColor: customColor
        )
    }
}

private final class WaveformDrawingView: NSView, AudioWaveformConsumer {
    private let barWidth: CGFloat = 1.25
    private let barSpacing: CGFloat = 0.9
    private var levels = Array(repeating: CGFloat(0.08), count: AudioWaveformModel.barCount)
    private var reducedMotion = false
    private var isPlaying = false
    private var colorMode: EqualizerColorMode = .gradient
    private var customColor = NSColor.labelColor
    private var artworkIdentifier: ObjectIdentifier?
    private var artworkGradient = ArtworkGradient.fallback

    override var isOpaque: Bool { false }

    /// The menu bar turns light or dark with the wallpaper behind it.
    private var isOnDarkBackground: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func displayWaveformLevels(_ levels: [CGFloat]) {
        guard !reducedMotion else { return }
        guard self.levels != levels else { return }
        self.levels = levels
        needsDisplay = true
    }

    func update(
        levels: [CGFloat],
        reducedMotion: Bool,
        isPlaying: Bool,
        artwork: NSImage?,
        colorMode: EqualizerColorMode,
        customColor: NSColor
    ) {
        let gradientChanged = updateArtworkGradient(from: artwork)
        guard gradientChanged
                || self.levels != levels
                || self.reducedMotion != reducedMotion
                || self.isPlaying != isPlaying
                || self.colorMode != colorMode
                || self.customColor != customColor
        else { return }
        self.levels = levels
        self.reducedMotion = reducedMotion
        self.isPlaying = isPlaying
        self.colorMode = colorMode
        self.customColor = customColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let count = min(AudioWaveformModel.barCount, levels.count)
        let totalWidth = CGFloat(count) * barWidth + CGFloat(max(0, count - 1)) * barSpacing
        let startX = (bounds.width - totalWidth) / 2 + barWidth / 2
        let time = Date.timeIntervalSinceReferenceDate
        let onDark = isOnDarkBackground

        for index in 0..<count {
            let level = isPlaying ? min(1, max(0, levels[index])) : 0.08
            let height = 1.5 + level * 14
            let x = startX + CGFloat(index) * (barWidth + barSpacing)
            let path = NSBezierPath()
            path.lineWidth = barWidth
            path.lineCapStyle = .round
            path.move(to: NSPoint(x: x, y: (bounds.height - height) / 2))
            path.line(to: NSPoint(x: x, y: (bounds.height + height) / 2))
            color(index: index, count: count, time: time, onDark: onDark).setStroke()
            path.stroke()
        }
    }

    private func color(index: Int, count: Int, time: TimeInterval, onDark: Bool) -> NSColor {
        switch colorMode {
        case .gradient:
            // Cover colors are whatever the art is; a near-black cover on a
            // dark menu bar would otherwise hide the bars.
            return artworkGradient
                .color(at: Double(index) / Double(max(1, count - 1)))
                .legible(onDarkBackground: onDark)
        case .fixed:
            return customColor
        case .random:
            return NSColor(
                hue: (time * 0.08 + Double(index) * 0.137).truncatingRemainder(dividingBy: 1),
                saturation: 0.85,
                brightness: 1,
                alpha: 1
            )
        }
    }

    private func updateArtworkGradient(from artwork: NSImage?) -> Bool {
        let identifier = artwork.map(ObjectIdentifier.init)
        guard identifier != artworkIdentifier else { return false }
        artworkIdentifier = identifier
        artworkGradient = artwork.flatMap(ArtworkGradient.extract) ?? .fallback
        return true
    }
}

/// Two representative cover colors extracted once when the artwork object
/// changes. Sampling a fixed 8 x 8 grid from the already-small thumbnail is
/// cheap and avoids retaining another bitmap or doing work during animation.
private struct ArtworkGradient {
    let start: NSColor
    let end: NSColor

    static let fallback = ArtworkGradient(
        start: NSColor(red: 0.24, green: 0.95, blue: 0.35, alpha: 1),
        end: NSColor(red: 1, green: 0.43, blue: 0.12, alpha: 1)
    )

    static func extract(from image: NSImage) -> ArtworkGradient? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let xStep = max(1, bitmap.pixelsWide / 8)
        let yStep = max(1, bitmap.pixelsHigh / 8)
        var candidates: [(color: NSColor, saturation: CGFloat, brightness: CGFloat)] = []

        for y in stride(from: yStep / 2, to: bitmap.pixelsHigh, by: yStep) {
            for x in stride(from: xStep / 2, to: bitmap.pixelsWide, by: xStep) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.5
                else { continue }
                var hue: CGFloat = 0
                var saturation: CGFloat = 0
                var brightness: CGFloat = 0
                var alpha: CGFloat = 0
                color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                guard brightness > 0.08 else { continue }
                candidates.append((color, saturation, brightness))
            }
        }

        guard let first = candidates.max(by: { vibrancy($0) < vibrancy($1) }) else { return nil }
        let second = candidates.max { lhs, rhs in
            contrast(from: first.color, candidate: lhs) < contrast(from: first.color, candidate: rhs)
        } ?? first

        if colorDistance(first.color, second.color) < 0.16 {
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            first.color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            return ArtworkGradient(
                start: NSColor(
                    hue: hue,
                    saturation: max(0.4, saturation),
                    brightness: max(0.32, brightness * 0.65),
                    alpha: 1
                ),
                end: NSColor(
                    hue: hue,
                    saturation: max(0.3, saturation * 0.8),
                    brightness: min(1, brightness * 1.25 + 0.12),
                    alpha: 1
                )
            )
        }

        return first.brightness <= second.brightness
            ? ArtworkGradient(start: first.color, end: second.color)
            : ArtworkGradient(start: second.color, end: first.color)
    }

    func color(at progress: Double) -> NSColor {
        let amount = CGFloat(min(1, max(0, progress)))
        let lhs = start.usingColorSpace(.sRGB) ?? start
        let rhs = end.usingColorSpace(.sRGB) ?? end
        return NSColor(
            red: lhs.redComponent + (rhs.redComponent - lhs.redComponent) * amount,
            green: lhs.greenComponent + (rhs.greenComponent - lhs.greenComponent) * amount,
            blue: lhs.blueComponent + (rhs.blueComponent - lhs.blueComponent) * amount,
            alpha: 1
        )
    }

    private static func vibrancy(
        _ candidate: (color: NSColor, saturation: CGFloat, brightness: CGFloat)
    ) -> CGFloat {
        candidate.saturation * 0.7 + candidate.brightness * 0.3
    }

    private static func contrast(
        from color: NSColor,
        candidate: (color: NSColor, saturation: CGFloat, brightness: CGFloat)
    ) -> CGFloat {
        colorDistance(color, candidate.color) * 0.8 + candidate.saturation * 0.2
    }

    private static func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let left = lhs.usingColorSpace(.sRGB) ?? lhs
        let right = rhs.usingColorSpace(.sRGB) ?? rhs
        let red = left.redComponent - right.redComponent
        let green = left.greenComponent - right.greenComponent
        let blue = left.blueComponent - right.blueComponent
        return sqrt(red * red + green * green + blue * blue)
    }
}

extension NSColor {
    /// The same hue, lifted on a dark background or deepened on a light
    /// one until it stands out from it.
    func legible(onDarkBackground: Bool) -> NSColor {
        guard let color = usingColorSpace(.sRGB) else { return self }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let adjusted = onDarkBackground ? max(brightness, 0.6) : min(brightness, 0.7)
        guard adjusted != brightness else { return color }
        return NSColor(hue: hue, saturation: saturation, brightness: adjusted, alpha: alpha)
    }
}

/// Single-line text clamped to `maxWidth`. When the text is wider, it holds
/// for the configured delay (or until the mouse hovers the item), scrolls
/// right-to-left to reveal the rest, holds, then eases back — repeating
/// while music plays. With Reduce Motion it stays put, cut off with a fade.
struct MarqueeText: View {
    let text: String
    let maxWidth: CGFloat
    var fontSize: CGFloat = 12
    @ObservedObject var model: TrackModel
    @ObservedObject var settings: AppSettings

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0

    private let scrollSpeed: CGFloat = 30 // points per second

    private static func font(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .medium)
    }

    /// Measured from the string instead of read back from layout, so the
    /// item has its final width on the first frame of a new title.
    static func width(of text: String, fontSize: CGFloat = 12) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font(size: fontSize)]).width)
    }

    /// Short titles give the room back to the menu bar when `fit` is on.
    static func frameWidth(textWidth: CGFloat, maxWidth: CGFloat, fit: Bool) -> CGFloat {
        fit ? min(textWidth, maxWidth) : maxWidth
    }

    private var fullTextWidth: CGFloat { Self.width(of: text, fontSize: fontSize) }

    private var needsScroll: Bool { fullTextWidth > maxWidth }

    var body: some View {
        Text(text)
            .font(Font(Self.font(size: fontSize)))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: offset)
            .frame(
                width: Self.frameWidth(textWidth: fullTextWidth, maxWidth: maxWidth, fit: settings.fitTitleToContent),
                alignment: needsScroll ? .leading : .center
            )
            .clipped()
            .mask(edgeFadeMask)
            .task(id: animationID) { await runMarquee() }
    }

    /// Soft fade on the clipped edges so scrolling text doesn't cut off hard.
    /// Leading fade only once scrolled — at rest it would cover the first letter.
    private var edgeFadeMask: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: needsScroll && offset < -0.5 ? 6 : 0)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: needsScroll ? 6 : 0)
        }
    }

    private func runMarquee() async {
        offset = 0
        guard needsScroll, model.screenActive, !reduceMotion else { return }
        while !Task.isCancelled {
            if !model.isHovering {
                // Paused: nothing to follow along with, so only a hover
                // scrolls. Saves waking up every few seconds for nothing.
                guard model.isPlaying else { return }
                do {
                    try await Task.sleep(for: .seconds(settings.holdSeconds))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, model.screenActive else { return }

            let distance = fullTextWidth - maxWidth + 8
            let duration = Double(distance / scrollSpeed)
            withAnimation(.linear(duration: duration)) {
                offset = -distance
            }
            do {
                try await Task.sleep(for: .seconds(duration + 2))
            } catch {
                return
            }

            withAnimation(.easeInOut(duration: 0.6)) {
                offset = 0
            }

            do {
                try await Task.sleep(for: .milliseconds(600))
            } catch {
                return
            }
        }
    }

    private var animationID: MarqueeAnimationID {
        MarqueeAnimationID(
            text: text,
            maxWidth: maxWidth,
            isHovering: model.isHovering,
            isPlaying: model.isPlaying,
            screenActive: model.screenActive,
            reduceMotion: reduceMotion,
            holdSeconds: settings.holdSeconds
        )
    }
}

private struct MarqueeAnimationID: Hashable {
    let text: String
    let maxWidth: CGFloat
    let isHovering: Bool
    let isPlaying: Bool
    let screenActive: Bool
    let reduceMotion: Bool
    let holdSeconds: Int
}
