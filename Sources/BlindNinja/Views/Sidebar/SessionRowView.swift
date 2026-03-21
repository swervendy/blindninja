import AppKit

/// A single session row — minimal: state dot + name.
final class SessionRowView: NSView {
    var onSelect: (() -> Void)?
    var onKill: (() -> Void)?
    var onRename: ((String) -> Void)?
    var onStar: (() -> Void)?
    var onRenameStarted: (() -> Void)?
    var onRenameEnded: (() -> Void)?

    let session: SessionInfo
    private let isActive: Bool
    private let theme: AppTheme
    private let nameField: NSTextField
    private let dotView: StateDotView
    private var renameField: NSTextField?
    private var isEndingRename = false

    init(session: SessionInfo, isActive: Bool, theme: AppTheme) {
        self.session = session
        self.isActive = isActive
        self.theme = theme
        self.nameField = NSTextField(labelWithString: "")
        self.dotView = StateDotView(state: session.state, theme: theme)
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 8

        if isActive {
            layer?.backgroundColor = theme.selectedBackground.cgColor
            layer?.borderWidth = 0.5
            layer?.borderColor = theme.borderColor.withAlphaComponent(0.6).cgColor
        }

        // State dot
        dotView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dotView)

        // Session name
        let displayName = session.customName ?? session.aiName ?? session.name
        nameField.stringValue = displayName
        nameField.font = .systemFont(ofSize: 12, weight: session.hasUnread ? .semibold : .medium)
        nameField.textColor = isActive ? theme.sidebarText : theme.sidebarText.withAlphaComponent(0.75)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.maximumNumberOfLines = 1
        nameField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameField)

        // Time ago label
        let timeAgo = formatTimeAgo(session.lastActivity)
        let timeLabel = NSTextField(labelWithString: timeAgo)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        timeLabel.textColor = theme.sidebarTextSecondary.withAlphaComponent(0.6)
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(timeLabel)

        // The anchor that nameField's trailing edge must stay before
        var nameTrailingAnchor = timeLabel.leadingAnchor
        var nameTrailingConstant: CGFloat = -6

        // Star (inserted between name and time)
        if session.starred {
            let star = NSTextField(labelWithString: "\u{2605}")
            star.font = .systemFont(ofSize: 9)
            star.textColor = theme.workingColor.withAlphaComponent(0.8)
            star.setContentCompressionResistancePriority(.required, for: .horizontal)
            star.setContentHuggingPriority(.required, for: .horizontal)
            star.translatesAutoresizingMaskIntoConstraints = false
            addSubview(star)
            NSLayoutConstraint.activate([
                star.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -4),
                star.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            nameTrailingAnchor = star.leadingAnchor
            nameTrailingConstant = -4
        }

        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 6),
            dotView.heightAnchor.constraint(equalToConstant: 6),

            nameField.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 10),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: nameTrailingAnchor, constant: nameTrailingConstant),

            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        // Hover
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 1 {
            onSelect?()
        }
    }

    func startRename() {
        guard renameField == nil else { return }
        let displayName = session.customName ?? session.aiName ?? session.name
        let field = NSTextField(string: displayName)
        field.font = .systemFont(ofSize: 13)
        field.textColor = .black
        field.backgroundColor = .white
        field.drawsBackground = true
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        nameField.isHidden = true
        renameField = field
        onRenameStarted?()
        window?.makeFirstResponder(field)
    }

    override func mouseEntered(with event: NSEvent) {
        if !isActive { layer?.backgroundColor = theme.hoverBackground.cgColor }
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = isActive ? theme.selectedBackground.cgColor : NSColor.clear.cgColor
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Rename", action: #selector(ctxRename), keyEquivalent: "")
        menu.addItem(withTitle: session.starred ? "Unstar" : "Star", action: #selector(ctxStar), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Kill", action: #selector(ctxKill), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

    @objc private func ctxRename() { startRename() }
    @objc private func ctxStar() { onStar?() }
    @objc private func ctxKill() { onKill?() }

    private func formatTimeAgo(_ ms: UInt64) -> String {
        let seconds = (UInt64(Date().timeIntervalSince1970 * 1000) - ms) / 1000
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}

extension SessionRowView: NSTextFieldDelegate {
    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        guard !isEndingRename else { return true }
        isEndingRename = true
        let newName = fieldEditor.string.trimmingCharacters(in: .whitespaces)
        nameField.isHidden = false
        renameField?.removeFromSuperview()
        renameField = nil
        onRenameEnded?()
        if !newName.isEmpty { onRename?(newName) }
        return true
    }
}
