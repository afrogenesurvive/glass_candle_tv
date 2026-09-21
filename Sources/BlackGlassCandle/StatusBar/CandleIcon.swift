import AppKit

/// Drawing primitives for the menu bar item.
///
/// Everything is drawn with `NSBezierPath` at runtime rather than bundled as
/// PNGs. Two reasons: no binary assets in git, and a vector glyph stays crisp at
/// every scale factor without shipping @2x variants.
///
/// The menu bar glyph is drawn in `controlTextColor` rather than being a template
/// image, because it is composed alongside *coloured* elements (the flame bar) in
/// the same view. A template image cannot be tinted per-element.
enum CandleIcon {

    /// Menu bar height is 22pt on current macOS; the glyph sits centred in it.
    static let glyphSize = NSSize(width: 13, height: 16)

    // MARK: Flame colour

    /// The flame bar's colour, which is the actual signal in the menu bar.
    ///
    /// Deliberately not colour-blind safe on its own — the bar *height* also
    /// encodes the level, so the two channels agree rather than relying on hue.
    static func flameColor(for level: FlameLevel) -> NSColor {
        switch level {
        case .down:     return .tertiaryLabelColor
        case .clear:    return .systemBlue.withAlphaComponent(0.55)
        case .low:      return .systemGreen
        case .moderate: return .systemOrange
        case .high:     return .systemRed
        }
    }

    /// Bar height per level. `down` gets a short stub rather than nothing, so the
    /// element does not vanish and shift the layout.
    static func flameBarHeight(for level: FlameLevel) -> CGFloat {
        switch level {
        case .down:     return 3
        case .clear:    return 4
        case .low:      return 7
        case .moderate: return 10
        case .high:     return 14
        }
    }

    static let flameBarWidth: CGFloat = 3.5

    // MARK: Glyph

    /// Draw a small candle: wax column, wick, teardrop flame.
    ///
    /// Coordinates are normalised to `rect` so this works at any size.
    /// `-parameter flameAlpha:` lets the controller dim the glyph when the stack
    /// is unreachable without redrawing a different shape.
    static func drawGlyph(in rect: NSRect, color: NSColor, flameAlpha: CGFloat = 1.0) {
        let s = min(rect.width, rect.height)
        let x = rect.midX
        let y = rect.minY

        let bodyWidth = s * 0.42
        let bodyHeight = s * 0.46
        let bodyBottom = y + s * 0.06
        let bodyTop = bodyBottom + bodyHeight
        let corner = bodyWidth * 0.26

        // --- wax column -----------------------------------------------------
        let bodyRect = NSRect(
            x: x - bodyWidth / 2,
            y: bodyBottom,
            width: bodyWidth,
            height: bodyHeight
        )
        color.setFill()
        NSBezierPath(roundedRect: bodyRect, xRadius: corner, yRadius: corner).fill()

        // --- wick -----------------------------------------------------------
        let wickBottom = bodyTop - s * 0.02
        let wickTop = bodyTop + s * 0.07
        let wick = NSBezierPath()
        wick.move(to: NSPoint(x: x, y: wickBottom))
        wick.line(to: NSPoint(x: x, y: wickTop))
        wick.lineWidth = max(1, s * 0.075)
        wick.lineCapStyle = .round
        color.setStroke()
        wick.stroke()

        // --- flame ----------------------------------------------------------
        // Teardrop: a circular base tapering to a point, matching gen_icon.py.
        let flameBase = wickTop - s * 0.01
        let flameTip = y + s * 0.98
        let baseRadius = s * 0.17
        let baseCenterY = flameBase + baseRadius
        let span = flameTip - baseCenterY

        guard span > 0 else { return }

        let flame = NSBezierPath()
        flame.move(to: NSPoint(x: x, y: flameTip))

        // Right side: sweep down from the tip to the widest point.
        flame.curve(
            to: NSPoint(x: x + baseRadius, y: baseCenterY),
            controlPoint1: NSPoint(x: x + baseRadius * 0.90, y: baseCenterY + span * 0.68),
            controlPoint2: NSPoint(x: x + baseRadius, y: baseCenterY + span * 0.22)
        )
        // Round the base.
        flame.appendArc(
            withCenter: NSPoint(x: x, y: baseCenterY),
            radius: baseRadius,
            startAngle: 0,
            endAngle: 180,
            clockwise: false
        )
        // Left side: sweep back up to the tip.
        flame.curve(
            to: NSPoint(x: x, y: flameTip),
            controlPoint1: NSPoint(x: x - baseRadius, y: baseCenterY + span * 0.22),
            controlPoint2: NSPoint(x: x - baseRadius * 0.90, y: baseCenterY + span * 0.68)
        )
        flame.close()

        color.withAlphaComponent(color.alphaComponent * flameAlpha).setFill()
        flame.fill()
    }

    /// The same glyph, as an `NSImage`, for the About panel and error states.
    /// Marked as a template so AppKit handles light/dark appearance.
    static func image(size: NSSize = NSSize(width: 64, height: 64)) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            drawGlyph(in: rect, color: .black)
            return true
        }
        image.isTemplate = true
        return image
    }
}
