import AppKit

/// A single session row — state indicator + name, styled by SidebarSettings.
final class SessionRowView: NSView {
    var onSelect: (() -> Void)?
    var onKill: (() -> Void)?
    var onRename: ((String) -> Void)?
    var onStar: (() -> Void)?
    var onRenameStarted: (() -> Void)?
    var onRenameEnded: (() -> Void)?

    let session: SessionInfo
    private let isActive: Bool
    private let isMultiSelected: Bool
    private let theme: AppTheme
    private let nameField: NSTextField
    private let dotView: StateDotView
    private let density: SidebarDensity
    private let indicatorStyle: IndicatorStyle
    private var renameField: NSTextField?
    private var nameStackView: NSStackView?
    private var isEndingRename = false

    init(session: SessionInfo, isActive: Bool, theme: AppTheme, isMultiSelected: Bool = false) {
        self.session = session
        self.isActive = isActive
        self.isMultiSelected = isMultiSelected
        self.theme = theme
        self.density = SidebarSettings.density
        self.indicatorStyle = SidebarSettings.indicatorStyle
        self.nameField = NSTextField(labelWithString: "")
        self.dotView = StateDotView(state: session.state, theme: theme,
                                     style: indicatorStyle, density: density)
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
        } else if isMultiSelected {
            layer?.backgroundColor = theme.selectedBackground.withAlphaComponent(0.5).cgColor
            layer?.borderWidth = 0.5
            layer?.borderColor = theme.waitingColor.withAlphaComponent(0.4).cgColor
        }

        // State indicator
        dotView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dotView)

        // Session name
        let displayName = session.customName ?? session.aiName ?? session.name
        nameField.stringValue = displayName
        nameField.font = .systemFont(ofSize: density.nameFontSize,
                                      weight: session.hasUnread ? .semibold : .medium)
        nameField.textColor = isActive ? theme.sidebarText : theme.sidebarText.withAlphaComponent(0.85)
        nameField.isBordered = false
        nameField.isEditable = false
        nameField.drawsBackground = false
        nameField.lineBreakMode = .byTruncatingTail
        nameField.maximumNumberOfLines = 1
        nameField.translatesAutoresizingMaskIntoConstraints = false

        // Branch label (shown when worktree branch differs from display name)
        var branchLabel: NSTextField? = nil
        if let branch = session.branchName, branch != displayName {
            let bl = NSTextField(labelWithString: branch)
            bl.font = .systemFont(ofSize: density.branchFontSize, weight: .regular)
            bl.textColor = theme.sidebarTextSecondary.withAlphaComponent(0.5)
            bl.lineBreakMode = .byTruncatingTail
            bl.maximumNumberOfLines = 1
            bl.translatesAutoresizingMaskIntoConstraints = false
            branchLabel = bl
        }

        // Stack name + optional branch vertically
        if let bl = branchLabel {
            let nameStack = NSStackView(views: [nameField, bl])
            nameStack.orientation = .vertical
            nameStack.alignment = .leading
            nameStack.spacing = -1
            nameStack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(nameStack)
            nameStackView = nameStack
        } else {
            addSubview(nameField)
        }

        // Time ago label
        let timeAgo = formatTimeAgo(session.lastActivity)
        let timeLabel = NSTextField(labelWithString: timeAgo)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: density.branchFontSize, weight: .regular)
        timeLabel.textColor = theme.sidebarTextSecondary.withAlphaComponent(0.6)
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(timeLabel)

        // The anchor that nameField's trailing edge must stay before
        var nameTrailingAnchor = timeLabel.leadingAnchor
        var nameTrailingConstant: CGFloat = -6

        // Star (inserted between name and time)
        if session.starred {
            let star = NSTextField(labelWithString: "\u{2605}")
            star.font = .systemFont(ofSize: density.branchFontSize)
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

        let iSize = dotView.indicatorSize
        let nameAnchorView: NSView = nameStackView ?? nameField

        // Layout depends on indicator style
        switch indicatorStyle {
        case .bar:
            // Bar sits at left edge, stretches vertically
            NSLayoutConstraint.activate([
                dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                dotView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                dotView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
                dotView.widthAnchor.constraint(equalToConstant: iSize.width),

                nameAnchorView.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 10),
                nameAnchorView.centerYAnchor.constraint(equalTo: centerYAnchor),
                nameAnchorView.trailingAnchor.constraint(lessThanOrEqualTo: nameTrailingAnchor, constant: nameTrailingConstant),
            ])
        case .dot, .ring:
            NSLayoutConstraint.activate([
                dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
                dotView.widthAnchor.constraint(equalToConstant: iSize.width),
                dotView.heightAnchor.constraint(equalToConstant: iSize.height),

                nameAnchorView.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 10),
                nameAnchorView.centerYAnchor.constraint(equalTo: centerYAnchor),
                nameAnchorView.trailingAnchor.constraint(lessThanOrEqualTo: nameTrailingAnchor, constant: nameTrailingConstant),
            ])
        }

        NSLayoutConstraint.activate([
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

    func startRename() {
        guard renameField == nil else { return }
        let displayName = session.customName ?? session.aiName ?? session.name
        let field = NSTextField(string: displayName)
        field.font = .systemFont(ofSize: density.nameFontSize)
        field.textColor = theme.sidebarText
        field.backgroundColor = theme.headerBackground
        field.drawsBackground = true
        field.isBordered = true
        field.focusRingType = .exterior
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
        if isActive {
            layer?.backgroundColor = theme.selectedBackground.cgColor
        } else if isMultiSelected {
            layer?.backgroundColor = theme.selectedBackground.withAlphaComponent(0.5).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if isMultiSelected {
            menu.addItem(withTitle: "Kill Selected", action: #selector(ctxKill), keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "Rename", action: #selector(ctxRename), keyEquivalent: "")
            menu.addItem(withTitle: session.starred ? "Unstar" : "Star", action: #selector(ctxStar), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Kill", action: #selector(ctxKill), keyEquivalent: "")
        }
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
