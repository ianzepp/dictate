import AppKit

/// A small pill near the bottom of the active screen that shows what Dictate is
/// doing. It never takes focus, and it floats over full-screen apps. The close
/// button is the only thing in it that takes a click.
final class Overlay {
    /// Called when the close button is clicked.
    var onClose: (() -> Void)?
    private let panel: NSPanel
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let meter = LevelMeter()
    private let spinner = NSProgressIndicator()
    private let closeButton = NSButton()
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 230, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 22
        background.layer?.masksToBounds = true
        panel.contentView = background

        icon.symbolConfiguration = .init(pointSize: 16, weight: .semibold)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        spinner.style = .spinning
        spinner.controlSize = .small
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel")
        closeButton.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Cancel"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [icon, label, meter, spinner, spacer, closeButton])
        row.orientation = .horizontal
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            row.widthAnchor.constraint(equalTo: background.widthAnchor),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            meter.widthAnchor.constraint(equalToConstant: 44),
            meter.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    func listening() {
        show(symbol: "mic.fill", tint: .systemRed, text: "Listening")
        meter.isHidden = false
        meter.level = 0
    }

    func working() {
        show(symbol: "waveform", tint: .secondaryLabelColor, text: "Transcribing")
        spinner.isHidden = false
        spinner.startAnimation(nil)
    }

    func done(_ text: String) {
        show(symbol: "checkmark.circle.fill", tint: .systemGreen, text: text)
        hide(after: 0.8)
    }

    func failed(_ text: String) {
        show(symbol: "exclamationmark.triangle.fill", tint: .systemOrange, text: text)
        hide(after: 2.0)
    }

    /// Hide at once, as after a cancel.
    func dismiss() {
        hideWork?.cancel()
        hideWork = nil
        panel.orderOut(nil)
    }

    @objc private func closeClicked() {
        onClose?()
    }

    func level(_ value: Float) {
        meter.level = value
    }

    private func show(symbol: String, tint: NSColor, text: String) {
        hideWork?.cancel()
        hideWork = nil
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        icon.contentTintColor = tint
        label.stringValue = text
        meter.isHidden = true
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        if !panel.isVisible {
            place()
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    private func hide(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Bottom center of the screen under the mouse, which is where the user is working.
    private func place() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 80))
    }
}

/// Five bars that rise with the microphone level, 0 to 1.
private final class LevelMeter: NSView {
    private static let weights: [CGFloat] = [0.5, 0.8, 1.0, 0.8, 0.5]

    var level: Float = 0 {
        didSet {
            // Rise fast, fall slowly, so speech reads as steady movement.
            let target = CGFloat(max(0, min(1, level)))
            shown = target > shown ? target : shown * 0.85 + target * 0.15
            needsDisplay = true
        }
    }

    private var shown: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        let count = CGFloat(Self.weights.count)
        let gap: CGFloat = 4
        let width = (bounds.width - gap * (count - 1)) / count
        NSColor.systemRed.setFill()
        for (index, weight) in Self.weights.enumerated() {
            let height = max(3, bounds.height * shown * weight)
            let x = CGFloat(index) * (width + gap)
            let rect = NSRect(x: x, y: (bounds.height - height) / 2, width: width, height: height)
            NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2).fill()
        }
    }
}
