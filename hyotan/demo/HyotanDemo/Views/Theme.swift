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

/// The gourd mark: two circles (upper r 11, lower r 18, centres 30 apart) joined by arcs of
/// radius 4 that are tangent to both, plus a short curved stem. Drawn in a 44×73 box.
struct GourdShape: Shape {
    static let aspect: CGFloat = 44.0 / 73.0

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 44, rect.height / 73)
        // Model space has the lower circle's centre at the origin; the box spans x -22…22, y -51…22.
        let origin = CGPoint(x: rect.midX, y: rect.midY + 14.5 * scale)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * scale, y: origin.y + y * scale) }
        func arc(_ path: inout Path, _ cx: CGFloat, _ cy: CGFloat, _ radius: CGFloat, _ from: CGFloat, _ to: CGFloat, clockwise: Bool) {
            path.addArc(center: point(cx, cy), radius: radius * scale, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: clockwise)
        }
        var path = Path()
        path.move(to: point(0, -41))
        path.addCurve(to: point(5, -47.5), control1: point(0, -44.5), control2: point(1.8, -46.8))
        path.move(to: point(0, -41))
        arc(&path, 0, -30, 11, -90, 45.4, clockwise: false)
        arc(&path, 10.53, -19.32, 4, 225.4, 118.6, clockwise: true)
        arc(&path, 0, 0, 18, -61.4, 241.4, clockwise: false)
        arc(&path, -10.53, -19.32, 4, 61.4, -45.4, clockwise: true)
        arc(&path, 0, -30, 11, 134.6, 270, clockwise: false)
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
            .frame(width: height * GourdShape.aspect, height: height)
            .accessibilityHidden(true)
    }
}
