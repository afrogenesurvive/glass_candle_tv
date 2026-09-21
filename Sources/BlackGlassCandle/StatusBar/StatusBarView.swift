import AppKit

/// The menu bar item's content: candle glyph, optional count text, flame bar.
///
/// A custom `NSView` rather than a title string, because the flame indicator is
/// drawn with real colours and a title string cannot carry an attributed image
/// plus per-element colours reliably at every appearance setting.
@MainActor
final class StatusBarView: NSView {

    weak var target: AnyObject?
    var action: Selector?
    var rightAction: Selector?

    // MARK: Content

    var flameLevel: FlameLevel = .clear {
        didSet { if oldValue != flameLevel { invalidate() } }
    }

    var text: String = "" {
        didSet { if oldValue != text { invalidate() } }
    }

    var showFlame: Bool = true {
        didSet { if oldValue != showFlame { invalidate() } }
    }

    var showIcon: Bool = true {
        didSet { if oldValue != showIcon { invalidate() } }
    }

    /// Slow pulse on the flame when unread pressure is high. Driven by the
    /// controller's timer, so the view stays a pure function of its inputs.
    var pulsePhase: CGFloat = 1.0 {
        didSet {
            if abs(oldValue - pulsePhase) > 0.01 { needsDisplay = true }
        }
    }

    // MARK: Layout constants

    private let horizontalPadding: CGFloat = 1
    private let elementGap: CGFloat = 3
    private let itemHeight: CGFloat = 22

    // MARK: Text attributes

    private var textAttributes: [NSAttributedString.Key: Any] {
        // Monospaced digits so the item does not jitter as counts change width
        // (9 -> 10 -> 100).
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        return [
            .font: font,
            .foregroundColor: NSColor.controlTextColor,
        ]
    }

    private var textWidth: CGFloat {
        guard !text.isEmpty else { return 0 }
        return ceil((text as NSString).size(withAttributes: textAttributes).width)
    }

    /// Total width the status item needs. The controller assigns this to
    /// `NSStatusItem.length`.
    var preferredWidth: CGFloat {
        var width = horizontalPadding * 2
        var elements = 0

        if showIcon { width += CandleIcon.glyphSize.width; elements += 1 }
        if textWidth > 0 { width += textWidth; elements += 1 }
        if showFlame { width += CandleIcon.flameBarWidth; elements += 1 }

        if elements > 1 {
            width += CGFloat(elements - 1) * elementGap
        }
        return max(width, showIcon ? CandleIcon.glyphSize.width + 2 : 8)
    }

    // MARK: Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StatusBarView is code-only")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredWidth, height: itemHeight)
    }

    private func invalidate() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        var cursor = bounds.minX + horizontalPadding

        // --- candle glyph ---------------------------------------------------
        if showIcon {
            let glyphRect = NSRect(
                x: cursor,
                y: bounds.midY - CandleIcon.glyphSize.height / 2,
                width: CandleIcon.glyphSize.width,
                height: CandleIcon.glyphSize.height
            )
            // Dim the whole glyph when disconnected: the state is "no signal",
            // and a bright candle would read as "all good".
            let alpha: CGFloat = flameLevel == .down ? 0.45 : 1.0
            CandleIcon.drawGlyph(in: glyphRect, color: .controlTextColor, flameAlpha: alpha)
            cursor = glyphRect.maxX + elementGap
        }

        // --- count text -----------------------------------------------------
        if !text.isEmpty {
            let size = (text as NSString).size(withAttributes: textAttributes)
            let textRect = NSRect(
                x: cursor,
                y: bounds.midY - size.height / 2,
                width: ceil(size.width),
                height: size.height
            )
            (text as NSString).draw(in: textRect, withAttributes: textAttributes)
            cursor = textRect.maxX + elementGap
        }

        // --- flame bar ------------------------------------------------------
        if showFlame {
            let height = CandleIcon.flameBarHeight(for: flameLevel)
            let barRect = NSRect(
                x: cursor,
                y: bounds.midY - height / 2,
                width: CandleIcon.flameBarWidth,
                height: height
            )
            let path = NSBezierPath(
                roundedRect: barRect,
                xRadius: CandleIcon.flameBarWidth / 2,
                yRadius: CandleIcon.flameBarWidth / 2
            )
            let colour = CandleIcon.flameColor(for: flameLevel)
            colour.withAlphaComponent(colour.alphaComponent * pulsePhase).setFill()
            path.fill()
        }
    }

    // MARK: Interaction

    // The view is a subview of the status item's button, so it receives clicks
    // first. Forwarding them to target/action keeps left-click and right-click
    // distinct, which a plain NSStatusItem action cannot do.

    override func mouseDown(with event: NSEvent) {
        guard let target, let action else { return }
        _ = target.perform(action, with: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let target, let rightAction else {
            super.rightMouseDown(with: event)
            return
        }
        _ = target.perform(rightAction, with: self)
    }
}
