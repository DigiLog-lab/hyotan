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

/// The gourd mark, drawn in a 48×64 box.
struct GourdShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 48, rect.height / 64)
        let origin = CGPoint(x: rect.midX - 24 * scale, y: rect.midY - 32 * scale)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * scale, y: origin.y + y * scale) }
        var path = Path()
        path.move(to: point(24, 8))
        path.addCurve(to: point(30, 3), control1: point(24, 5), control2: point(26, 3))
        path.move(to: point(24, 8))
        path.addCurve(to: point(15, 18), control1: point(18, 8), control2: point(15, 13))
        path.addCurve(to: point(18, 26), control1: point(15, 22), control2: point(17, 24))
        path.addCurve(to: point(8, 43), control1: point(12, 29), control2: point(8, 35))
        path.addCurve(to: point(24, 62), control1: point(8, 54), control2: point(15, 62))
        path.addCurve(to: point(40, 43), control1: point(33, 62), control2: point(40, 54))
        path.addCurve(to: point(30, 26), control1: point(40, 35), control2: point(36, 29))
        path.addCurve(to: point(33, 18), control1: point(31, 24), control2: point(33, 22))
        path.addCurve(to: point(24, 8), control1: point(33, 13), control2: point(30, 8))
        return path
    }
}

struct GourdMark: View {
    var height: CGFloat
    var lineWidth: CGFloat

    var body: some View {
        GourdShape()
            .stroke(Palette.ochre, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .frame(width: height * 0.75, height: height)
            .accessibilityHidden(true)
    }
}
