import SwiftUI

/// The Loqi brand mark: one horizontal sine wave.
///
/// `amplitude` (0...1) scales the wave height inside its frame — 0 is a flat
/// line, 1 fills the rect. Leave it static for branding (dividers, headers,
/// empty states); drive it from live mic level for the "listening" state.
struct LoqiWave: Shape {
    /// 0 = flat, 1 = full height.
    var amplitude: CGFloat = 0.7
    /// Number of crests across the width.
    var cycles: CGFloat = 2

    // Let `.animation(_:value:)` interpolate as the level changes.
    var animatableData: CGFloat {
        get { amplitude }
        set { amplitude = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let amp = (rect.height / 2) * max(0, min(1, amplitude))
        // ponytail: 60-segment polyline, not a bezier. Plenty smooth for a
        // thin stroke; bump `steps` if it ever looks faceted at large sizes.
        let steps = 60
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = rect.width * t
            let y = rect.midY - sin(cycles * 2 * .pi * t) * amp
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
            else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }
}

/// Static brand wave for dividers, headers, and empty states.
struct LoqiWaveMark: View {
    var height: CGFloat = 24
    var lineWidth: CGFloat = 2.5

    var body: some View {
        LoqiWave(amplitude: 0.6, cycles: 2)
            .stroke(
                Color.accentColor,
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

#Preview {
    VStack(spacing: 32) {
        LoqiWaveMark()
        // Listening states: amplitude tracks mic level.
        LoqiWave(amplitude: 0.2).stroke(Color.accentColor, lineWidth: 3).frame(height: 40)
        LoqiWave(amplitude: 0.9).stroke(Color.accentColor, lineWidth: 3).frame(height: 40)
    }
    .padding(40)
}
