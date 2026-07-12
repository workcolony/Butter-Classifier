import SwiftUI

/// Draggable playhead scrubber with a larger hit target than the system slider.
struct PlaybackScrubber: View {
    let currentTime: Double
    let duration: Double
    var onSeek: (Double) -> Void

    @State private var dragging = false
    @State private var dragTime: Double = 0

    private var displayTime: Double {
        dragging ? dragTime : currentTime
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let fraction = CGFloat(min(1, max(0, displayTime / max(duration, 0.0001))))
            let thumbX = fraction * width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: 5)
                Capsule()
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(width: max(0, thumbX), height: 5)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                    .offset(x: max(0, min(width - 14, thumbX - 7)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        let frac = Double(max(0, min(1, value.location.x / width)))
                        dragTime = frac * max(duration, 0.0001)
                        onSeek(dragTime)
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(height: 28)
    }
}
