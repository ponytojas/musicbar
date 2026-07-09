import SwiftUI

/// Content of the menu bar item: a state icon plus the track title in a
/// fixed-width marquee.
struct StatusBarView: View {
    @ObservedObject var model: TrackModel
    @ObservedObject var settings = AppSettings.shared

    private var displayText: String {
        settings.showArtist ? model.displayText : model.title
    }

    var body: some View {
        HStack(spacing: 6) {
            if settings.showArtwork, let artwork = model.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 17, height: 17)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }

            if model.hasTrack {
                if settings.showEqualizer {
                    EqualizerView(isPlaying: model.isPlaying, screenActive: model.screenActive)
                }

                MarqueeText(text: displayText, maxWidth: settings.textWidth, model: model, settings: settings)
                    .id(displayText)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 22)
        .clipped()
        .animation(.spring(duration: 0.4), value: displayText)
        .animation(.spring(duration: 0.4), value: model.isPlaying)
        .animation(.spring(duration: 0.4), value: model.artwork != nil)
        .animation(.spring(duration: 0.4), value: settings.showArtwork)
        .animation(.spring(duration: 0.4), value: settings.showEqualizer)
        .animation(.spring(duration: 0.4), value: settings.textWidth)
    }
}

/// Three animated bars while playing; frozen low bars while paused.
/// Stops redrawing entirely when the screen is locked or asleep.
struct EqualizerView: View {
    let isPlaying: Bool
    var screenActive: Bool = true

    private let frequencies: [Double] = [4.1, 5.3, 3.4]
    private let phases: [Double] = [0, 1.3, 2.6]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !(isPlaying && screenActive))) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .frame(width: 2, height: barHeight(index: index, time: time))
                }
            }
            .frame(width: 11, height: 12, alignment: .bottom)
            .animation(.easeOut(duration: 0.3), value: isPlaying)
        }
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        guard isPlaying else { return 3 }
        let normalized = (sin(time * frequencies[index] + phases[index]) + 1) / 2
        return 3 + normalized * 9
    }
}

/// Single-line text clamped to `maxWidth`. When the text is wider, it holds
/// for the configured delay (or until the mouse hovers the item), scrolls
/// right-to-left to reveal the rest, holds, then eases back — repeating.
struct MarqueeText: View {
    let text: String
    let maxWidth: CGFloat
    let model: TrackModel       // reference type: task reads live hover state
    let settings: AppSettings   // reference type: task reads live hold delay

    @State private var fullTextWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private let scrollSpeed: CGFloat = 30 // points per second

    private var needsScroll: Bool { fullTextWidth > maxWidth }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .background {
                GeometryReader { geo in
                    Color.clear.preference(key: TextWidthKey.self, value: geo.size.width)
                }
            }
            .offset(x: offset)
            .frame(width: maxWidth, alignment: needsScroll ? .leading : .center)
            .clipped()
            .mask(edgeFadeMask)
            .onPreferenceChange(TextWidthKey.self) { fullTextWidth = $0 }
            .task(id: text) { await runMarquee() }
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
        while !Task.isCancelled {
            // Hold until the interval elapses or the mouse hovers the item.
            var waited: Double = 0
            while waited < Double(settings.holdSeconds) && !model.isHovering {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
                waited += 0.1
            }
            guard needsScroll else {
                // Text fits; idle so a constant hover doesn't busy-loop.
                try? await Task.sleep(for: .seconds(1))
                continue
            }

            let distance = fullTextWidth - maxWidth + 8
            let duration = Double(distance / scrollSpeed)
            withAnimation(.linear(duration: duration)) {
                offset = -distance
            }
            try? await Task.sleep(for: .seconds(duration + 2))
            guard !Task.isCancelled else { return }

            withAnimation(.easeInOut(duration: 0.6)) {
                offset = 0
            }
        }
    }
}

private struct TextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
