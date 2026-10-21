import AppKit

/// What the status card at the top of the menu is showing. Symbols and colors
/// match the overlay, so the menu and the overlay read as one design.
enum StatusStyle {
    case ready
    case listening
    case working
    case done
    case problem
    case info

    var symbol: String {
        switch self {
        case .ready: return "mic"
        case .listening: return "mic.fill"
        case .working: return "waveform"
        case .done: return "checkmark.circle.fill"
        case .problem: return "exclamationmark.triangle.fill"
        case .info: return "xmark.circle"
        }
    }

    var tint: NSColor {
        switch self {
        case .ready, .info: return .secondaryLabelColor
        case .listening: return .systemRed
        case .working: return .systemBlue
        case .done: return .systemGreen
        case .problem: return .systemOrange
        }
    }
}

/// The menu's first row: a tinted icon badge, a bold state, and a detail line.
final class StatusRowView: NSView {
    private let badge = NSView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: RecentTranscriptView.menuWidth, height: 56))
        autoresizingMask = [.width]

        badge.wantsLayer = true
        badge.layer?.cornerRadius = 16
        icon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(icon)

        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        spinner.style = .spinning
        spinner.controlSize = .small

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let row = NSStackView(views: [badge, text, spinner])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 32),
            badge.heightAnchor.constraint(equalToConstant: 32),
            icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: RecentTranscriptView.menuWidth - 100),
        ])
        show(.ready, title: "Starting", detail: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ style: StatusStyle, title text: String, detail note: String?) {
        icon.image = NSImage(systemSymbolName: style.symbol, accessibilityDescription: text)
        icon.contentTintColor = style.tint
        paintBadge(style.tint)
        title.stringValue = text
        detail.stringValue = note ?? ""
        detail.isHidden = note == nil
        if style == .working {
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }
        // A two-line detail needs a taller row.
        let tall = note.map { $0.count > 48 } ?? false
        setFrameSize(NSSize(width: frame.width, height: tall ? 68 : 56))
    }

    /// Layer colors do not follow light and dark mode on their own.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let tint = icon.contentTintColor { paintBadge(tint) }
    }

    private func paintBadge(_ tint: NSColor) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            badge.layer?.backgroundColor = tint.withAlphaComponent(0.16).cgColor
        }
    }
}
