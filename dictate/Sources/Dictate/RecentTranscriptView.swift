import AppKit
import DictateCore

/// Two-line preview of one recent transcript. The menu item still carries the full text.
final class RecentTranscriptView: NSView {
    static let menuWidth: CGFloat = 340

    private let lines: [String]

    init(text: String) {
        lines = MenuPreview.lines(text)
        let height = Self.height(lineCount: max(1, lines.count))
        super.init(frame: NSRect(x: 0, y: 0, width: Self.menuWidth, height: height))
        autoresizingMask = [.width]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseUp(with event: NSEvent) {
        guard let item = enclosingMenuItem, let menu = item.menu else { return }
        let index = menu.index(of: item)
        guard index >= 0 else { return }
        menu.cancelTracking()
        menu.performActionForItem(at: index)
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = enclosingMenuItem?.isHighlighted == true
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.lineSpacing = 2
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        var textRect = bounds.insetBy(dx: 16, dy: 7)
        textRect.size.width -= 22
        lines.joined(separator: "\n").draw(in: textRect, withAttributes: attributes)
        if highlighted, let copy = Self.copyIcon {
            let size = copy.size
            let origin = NSPoint(x: bounds.maxX - 16 - size.width, y: bounds.midY - size.height / 2)
            copy.draw(in: NSRect(origin: origin, size: size))
        }
    }

    /// Shown on the highlighted row, as a hint that clicking copies.
    private static let copyIcon: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            .applying(.init(paletteColors: [.selectedMenuItemTextColor]))
        return NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")?
            .withSymbolConfiguration(config)
    }()

    private static func height(lineCount: Int) -> CGFloat {
        14 + CGFloat(lineCount) * 18
    }
}
