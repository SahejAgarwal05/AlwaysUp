import AppKit

/// Visual state of the AlwaysUp menu bar mark.
enum LogoState { case off, awake, saver }

/// The AlwaysUp mark: a closed "lid" bar with an "up" chevron rising above it.
/// Geometry is defined in a normalized unit square (origin bottom-left, y up)
/// shared with the app icon.
enum Logo {
    // Shared mark geometry (unit square).
    static let barY: CGFloat = 0.24
    static let barX0: CGFloat = 0.20, barX1: CGFloat = 0.80
    static let chevronLeft = CGPoint(x: 0.25, y: 0.47)
    static let chevronApex = CGPoint(x: 0.50, y: 0.72)
    static let chevronRight = CGPoint(x: 0.75, y: 0.47)
    static let chevronWidth: CGFloat = 0.12
    static let barWidth: CGFloat = 0.10

    /// Template image for the status bar (18x18pt, vector, auto-tinted by macOS).
    static func menuBar(_ state: LogoState) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            draw(state, in: rect)
            return true
        }
        image.isTemplate = true
        switch state {
        case .off: image.accessibilityDescription = "AlwaysUp (off)"
        case .awake: image.accessibilityDescription = "AlwaysUp (keeping Mac awake)"
        case .saver: image.accessibilityDescription = "AlwaysUp (awake, battery saver)"
        }
        return image
    }

    /// Draws the mark for `state` into `rect` using the current fill/stroke color.
    static func draw(_ state: LogoState, in rect: NSRect) {
        // Slight optical enlargement so the mark fills the bar like an SF Symbol,
        // while keeping ~1pt clear padding on every side at 18pt.
        let scale = rect.width * 1.12
        let ox = rect.minX + (rect.width - scale) / 2
        let oy = rect.minY + (rect.height - scale) / 2 + rect.height * 0.035
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * scale, y: oy + y * scale) }

        // Lid bar (identical in every state).
        // Snap the bar to whole points (even width, integer centre) so it stays crisp at @1x.
        let barW = max(1, (barWidth * scale).rounded())
        let barCenterY = p(0, barY).y.rounded() + (barW.truncatingRemainder(dividingBy: 2) == 1 ? 0.5 : 0)
        let bar = NSBezierPath()
        bar.move(to: NSPoint(x: p(barX0, 0).x, y: barCenterY))
        bar.line(to: NSPoint(x: p(barX1, 0).x, y: barCenterY))
        bar.lineWidth = barW
        bar.lineCapStyle = .round
        bar.stroke()

        let chevron = NSBezierPath()
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round

        switch state {
        case .awake, .saver:
            chevron.move(to: p(chevronLeft.x, chevronLeft.y))
            chevron.line(to: p(chevronApex.x, chevronApex.y))
            chevron.line(to: p(chevronRight.x, chevronRight.y))
            chevron.lineWidth = chevronWidth * scale
            chevron.stroke()

            if state == .saver {
                // Small solid dot nested under the chevron apex: "low power, still up".
                let c = p(0.50, 0.465)
                let r = 0.06 * scale
                NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
            }

        case .off:
            // Resting: chevron sinks and flattens toward the lid, drawn as a thin line.
            chevron.move(to: p(0.27, 0.42))
            chevron.line(to: p(0.50, 0.53))
            chevron.line(to: p(0.73, 0.42))
            chevron.lineWidth = 0.07 * scale
            chevron.stroke()
        }
    }
}
