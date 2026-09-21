import SwiftUI

enum Palette {
    static let ground = Color(red: 0.078, green: 0.071, blue: 0.055)
    static let well = Color(red: 0.051, green: 0.047, blue: 0.035)
    static let line = Color(red: 0.227, green: 0.208, blue: 0.161)
    static let text = Color(red: 0.925, green: 0.898, blue: 0.839)
    static let sub = Color(red: 0.659, green: 0.624, blue: 0.545)
    static let ochre = Color(red: 0.820, green: 0.647, blue: 0.290)
    static let green = Color(red: 0.561, green: 0.710, blue: 0.451)
    static let red = Color(red: 0.851, green: 0.510, blue: 0.420)
}

extension Font {
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// The gourd mark, drawn in a 64×64 box: a small upper bulb, a short waist and a lower bulb
/// that is wider than it is tall.
struct GourdShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 64
        let origin = CGPoint(x: rect.midX - 32 * scale, y: rect.midY - 32 * scale)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * scale, y: origin.y + y * scale) }
        var path = Path()
        path.move(to: point(32, 11))
        path.addCurve(to: point(37.5, 5), control1: point(32, 7.5), control2: point(34, 5.5))
        path.move(to: point(32, 11))
        path.addCurve(to: point(42.5, 21), control1: point(37.8, 11), control2: point(42.5, 15.5))
        path.addCurve(to: point(37.5, 31.5), control1: point(42.5, 26), control2: point(37.5, 27.5))
        path.addCurve(to: point(49.5, 44), control1: point(37.5, 35), control2: point(49.5, 36))
        path.addCurve(to: point(32, 59.5), control1: point(49.5, 52.6), control2: point(41.7, 59.5))
        path.addCurve(to: point(14.5, 44), control1: point(22.3, 59.5), control2: point(14.5, 52.6))
        path.addCurve(to: point(26.5, 31.5), control1: point(14.5, 36), control2: point(26.5, 35))
        path.addCurve(to: point(21.5, 21), control1: point(26.5, 27.5), control2: point(21.5, 26))
        path.addCurve(to: point(32, 11), control1: point(21.5, 15.5), control2: point(26.2, 11))
        path.closeSubpath()
        return path
    }
}

struct GourdMark: View {
    var height: CGFloat
    var lineWidth: CGFloat

    var body: some View {
        GourdShape()
            .stroke(Palette.ochre, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .frame(width: height, height: height)
            .accessibilityHidden(true)
    }
}
