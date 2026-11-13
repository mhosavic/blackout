import AppKit

/// The menu bar glyph, drawn in code so it needs no asset catalog (the
/// package builds with Command Line Tools alone). A template image: macOS
/// colors it for a light or dark menu bar.
enum MenuBarIcon {

    /// Off is an open ring — the sun, uncovered. On is an eclipse: a solid
    /// disc with an arc of corona showing past its edge.
    static func image(on: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let center = NSPoint(x: 9, y: 9)
            NSColor.black.set()

            func circle(radius: CGFloat) -> NSBezierPath {
                NSBezierPath(ovalIn: NSRect(
                    x: center.x - radius, y: center.y - radius,
                    width: radius * 2, height: radius * 2))
            }

            if on {
                circle(radius: 5.5).fill()
                let corona = NSBezierPath()
                corona.appendArc(withCenter: center, radius: 7.7, startAngle: -35, endAngle: 125)
                corona.lineWidth = 1.35
                corona.lineCapStyle = .round
                corona.stroke()
            } else {
                let ring = circle(radius: 6.4)
                ring.lineWidth = 1.5
                ring.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
