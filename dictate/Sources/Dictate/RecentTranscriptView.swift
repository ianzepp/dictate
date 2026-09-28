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
        let textRect = bounds.insetBy(dx: 16, dy: 7)
        lines.joined(separator: "\n").draw(in: textRect, withAttributes: attributes)
    }

    private static func height(lineCount: Int) -> CGFloat {
        14 + CGFloat(lineCount) * 18
    }
}
