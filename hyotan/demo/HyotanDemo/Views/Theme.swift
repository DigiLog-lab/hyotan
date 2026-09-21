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

/// The gourd mark. The body is two true circles (upper r 13.5, lower r 20, centres 31 apart)
/// joined by arcs of radius 5 tangent to both. The stem is a separate shape because it is
/// stroked heavier than the outline. Model box: 46×79.5. Generated from the same
/// parameters as the icon artwork.
enum Gourd {
    static let aspect: CGFloat = 46.0 / 79.5

    /// Maps model space (lower circle centred on the origin; y -56.5…23) into `rect`.
    static func transform(in rect: CGRect) -> CGAffineTransform {
        let scale = min(rect.width / 46, rect.height / 79.5)
        return CGAffineTransform(translationX: rect.midX, y: rect.midY - (-56.5 + 23) / 2 * scale).scaledBy(x: scale, y: scale)
    }
}

struct GourdBody: Shape {
    func path(in rect: CGRect) -> Path {
        let upper = CGPoint(x: 0, y: -31)
        var body = Path()
        body.move(to: CGPoint(x: 0, y: -44.5))
        body.addArc(center: upper, radius: 13.5, startAngle: .degrees(-90), endAngle: .degrees(36.25), clockwise: false)
        body.addArc(center: CGPoint(x: 14.919, y: -20.06), radius: 5, startAngle: .degrees(216.25), endAngle: .degrees(126.64), clockwise: true)
        body.addArc(center: .zero, radius: 20, startAngle: .degrees(-53.36), endAngle: .degrees(233.36), clockwise: false)
        body.addArc(center: CGPoint(x: -14.919, y: -20.06), radius: 5, startAngle: .degrees(53.36), endAngle: .degrees(-36.25), clockwise: true)
        body.addArc(center: upper, radius: 13.5, startAngle: .degrees(143.75), endAngle: .degrees(270), clockwise: false)
        body.closeSubpath()
        return body.applying(Gourd.transform(in: rect))
    }
}

struct GourdStem: Shape {
    func path(in rect: CGRect) -> Path {
        var stem = Path()
        stem.move(to: CGPoint(x: 0, y: -44.0))
        stem.addCurve(to: CGPoint(x: 5.5, y: -51.5), control1: CGPoint(x: 0, y: -48.0), control2: CGPoint(x: 2, y: -50.5))
        return stem.applying(Gourd.transform(in: rect))
    }
}

struct GourdMark: View {
    var height: CGFloat
    var lineWidth: CGFloat

    var body: some View {
        ZStack {
            GourdBody().stroke(Palette.ochre, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            GourdStem().stroke(Palette.ochre, style: StrokeStyle(lineWidth: lineWidth * 1.65, lineCap: .round))
        }
        .frame(width: height * Gourd.aspect, height: height)
        .accessibilityHidden(true)
    }
}
