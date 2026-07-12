import AppKit
import SwiftUI

/// Playback speed slider (0.25×–4×) centered at 1×, with Option-click on the handle to reset.
struct PlaybackSpeedSlider: View {
    @Binding var rate: Double

    private static let minRate = 0.25
    private static let centerRate = 1.0
    private static let maxRate = 4.0

    @State private var dragging = false
    @State private var dragRate: Double = 1.0

    private var displayRate: Double {
        dragging ? dragRate : rate
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let fraction = fractionForRate(displayRate)
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
                    .highPriorityGesture(thumbGesture(width: width))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(trackGesture(width: width))
        }
        .frame(height: 28)
    }

    private func thumbGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if NSEvent.modifierFlags.contains(.option) {
                    rate = Self.centerRate
                    dragging = false
                    return
                }
                dragging = true
                dragRate = rateForLocation(value.location.x, width: width)
                rate = dragRate
            }
            .onEnded { _ in dragging = false }
    }

    private func trackGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                dragging = true
                dragRate = rateForLocation(value.location.x, width: width)
                rate = dragRate
            }
            .onEnded { _ in dragging = false }
    }

    private func rateForLocation(_ x: CGFloat, width: CGFloat) -> Double {
        let fraction = Double(max(0, min(1, x / width)))
        return rateForFraction(fraction)
    }

    /// Linear slider position: left half is 0.25×–1×, right half is 1×–4×.
    private func fractionForRate(_ rate: Double) -> CGFloat {
        let clamped = min(max(rate, Self.minRate), Self.maxRate)
        if clamped <= Self.centerRate {
            let span = Self.centerRate - Self.minRate
            let fraction = (clamped - Self.minRate) / span * 0.5
            return CGFloat(fraction)
        }
        let span = Self.maxRate - Self.centerRate
        let fraction = 0.5 + (clamped - Self.centerRate) / span * 0.5
        return CGFloat(fraction)
    }

    private func rateForFraction(_ fraction: Double) -> Double {
        let clamped = min(max(fraction, 0), 1)
        let value: Double
        if clamped <= 0.5 {
            let span = Self.centerRate - Self.minRate
            value = Self.minRate + (clamped / 0.5) * span
        } else {
            let span = Self.maxRate - Self.centerRate
            value = Self.centerRate + ((clamped - 0.5) / 0.5) * span
        }
        return (value * 100).rounded() / 100
    }
}
