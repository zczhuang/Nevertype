import SwiftUI
import AppKit

/// The Nevertype mark: a bold, round-capped "N" (two uprights and a diagonal) with the diagonal in the accent colour.
///
/// It is plain geometry on purpose (no SF Symbols, no font), so the same numbers draw the in-app mark, the floating pill logo,
/// the menu bar icon and the app icon. `scripts/generate-icon.swift` repeats these proportions for the app icon; keep the two
/// in step.
enum NevertypeMarkGeometry {
    /// Stroke width as a fraction of the mark's side.
    static let strokeFraction: CGFloat = 0.17
    /// Horizontal position of the two uprights and the vertical span of the strokes, as fractions of the side.
    static let leftX: CGFloat = 0.25
    static let rightX: CGFloat = 0.75
    static let top: CGFloat = 0.20
    static let bottom: CGFloat = 0.80

    /// The two uprights as one path (stroke it with a round cap).
    static func uprights(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(leftX, top, in: rect))
        path.addLine(to: point(leftX, bottom, in: rect))
        path.move(to: point(rightX, top, in: rect))
        path.addLine(to: point(rightX, bottom, in: rect))
        return path
    }

    /// The diagonal, from the top of the left upright to the bottom of the right one.
    static func diagonal(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(leftX, top, in: rect))
        path.addLine(to: point(rightX, bottom, in: rect))
        return path
    }

    static func lineWidth(in rect: CGRect) -> CGFloat {
        min(rect.width, rect.height) * strokeFraction
    }

    private static func point(_ fx: CGFloat, _ fy: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * fx, y: rect.minY + rect.height * fy)
    }

    // Brand colours (also used by the app icon).
    static let teal = Color(red: 0.055, green: 0.298, blue: 0.341)        // #0E4C57
    static let tealLight = Color(red: 0.090, green: 0.439, blue: 0.478)   // #17707A
    static let coral = Color(red: 1.000, green: 0.420, blue: 0.290)       // #FF6B4A
}

/// The mark in full colour for light backgrounds: teal uprights and a coral diagonal.
public struct NevertypeMarkView: View {
    public var size: CGFloat = 24

    public init(size: CGFloat = 24) {
        self.size = size
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let rect = CGRect(origin: .zero, size: canvasSize)
            let style = StrokeStyle(lineWidth: NevertypeMarkGeometry.lineWidth(in: rect), lineCap: .round, lineJoin: .round)
            // Diagonal first, so the uprights sit over its two ends.
            context.stroke(NevertypeMarkGeometry.diagonal(in: rect), with: .color(NevertypeMarkGeometry.coral), style: style)
            context.stroke(
                NevertypeMarkGeometry.uprights(in: rect),
                with: .linearGradient(
                    Gradient(colors: [NevertypeMarkGeometry.tealLight, NevertypeMarkGeometry.teal]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                    endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                ),
                style: style
            )
        }
        .frame(width: size, height: size)
    }
}

/// The menu bar icon: the same mark as a single-colour template image, so macOS tints it for light and dark menu bars.
enum NevertypeMenuBarIcon {
    static func image(pointSize: CGFloat = 18) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size, flipped: true) { rect in
            let lineWidth = NevertypeMarkGeometry.lineWidth(in: rect)
            NSColor.black.setStroke()
            for path in [NevertypeMarkGeometry.diagonal(in: rect), NevertypeMarkGeometry.uprights(in: rect)] {
                let bezier = NSBezierPath(cgPath: path.cgPath)
                bezier.lineWidth = lineWidth
                bezier.lineCapStyle = .round
                bezier.lineJoinStyle = .round
                bezier.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
