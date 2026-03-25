import AppKit

private let sessionDragType = NSPasteboard.PasteboardType("com.blindninja.session-id")

private enum SidebarRow {
    case sectionHeader(String)
    case session(SessionInfo)
}

final class SidebarViewController: NSViewController {
    var onSessionSelected: ((String) -> Void)?
    var onSessionKill: ((String) -> Void)?
    var onSessionsKill: ((Set<String>) -> Void)?
    var onNewClaudeRequested: (() -> Void)?
    var onNewDeployRequested: (() -> Void)?
    var onNewShellRequested: (() -> Void)?
    var onThemeChanged: ((AppTheme) -> Void)?
    /// Optional filter — when set, sessions matching these IDs are excluded from the sidebar.
    var hiddenSessionIds: Set<String> = []
    /// When non-empty, only sessions in this set are shown (ownership filter from the parent window).
    var ownedSessionIds: Set<String> = []

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var sessions: [SessionInfo] = []  // flat filtered list for drag/drop
    private var rows: [SidebarRow] = []
    private var activeSessionId: String?
    private var currentTheme: AppTheme = .blueTitanium
    private var lastRefresh: Date = .distantPast
    private var headerContainer: NSView?
    private var footerContainer: NSView?
    private var shortcutsGuide: NSView?
    private var isRenaming = false
    private var worktreeToggle: NSSwitch?
    private var notifSoundToggle: NSSwitch?
    private var selectedSessionIds: Set<String> = []
    private var lastClickedRow: Int?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        col.title = ""
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        let density = SidebarSettings.density
        tableView.rowHeight = density.rowHeight
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: density.intercellSpacing)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.action = #selector(tableViewClick(_:))
        tableView.doubleAction = #selector(tableViewDoubleClick(_:))
        tableView.target = self
        tableView.registerForDraggedTypes([sessionDragType])
        tableView.draggingDestinationFeedbackStyle = .gap
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false

        let header = buildHeader()
        headerContainer = header
        header.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let footer = buildFooter()
        footerContainer = footer
        footer.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        view.addSubview(scrollView)
        view.addSubview(footer)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        applyTheme(currentTheme)
        refreshSessions()

        // Note: sessionsChanged is handled by SplitViewController which calls
        // refreshSessions() with throttle + filter updates. No separate observer here
        // to avoid double-processing and defeating the throttle.
    }

    func refreshSessions() {
        let now = Date()
        guard now.timeIntervalSince(lastRefresh) >= 0.3 else { return }
        forceRefreshSessions()
    }

    func forceRefreshSessions() {
        guard !isRenaming else { return }
        lastRefresh = Date()
        let all = SessionManager.shared.listSessions()
        // Filter out shell sessions (they live in the drawer), per-window hidden sessions,
        // and sessions not owned by this window
        sessions = all.filter {
            $0.sessionType != .shell
            && !hiddenSessionIds.contains($0.id)
            && (ownedSessionIds.isEmpty || ownedSessionIds.contains($0.id))
        }

        // Build rows with section headers
        let deploySessions = sessions.filter { $0.sessionType == .deploy }
        let claudeSessions = sessions.filter { $0.sessionType == .claude }

        var newRows: [SidebarRow] = []
        if !deploySessions.isEmpty {
            newRows.append(.sectionHeader("DEPLOY"))
            newRows.append(contentsOf: deploySessions.map { .session($0) })
        }
        if !claudeSessions.isEmpty {
            newRows.append(.sectionHeader("SESSIONS"))
            newRows.append(contentsOf: claudeSessions.map { .session($0) })
        }
        if deploySessions.isEmpty && claudeSessions.isEmpty {
            newRows.append(.sectionHeader("SESSIONS"))
        }

        // Differential update: if same structure, only reload visually changed rows.
        // This preserves StateDotView animations and avoids full table rebuilds.
        if rows.count == newRows.count && rowStructureMatches(rows, newRows) {
            var changedRows = IndexSet()
            for i in 0..<newRows.count {
                if case .session(let oldS) = rows[i],
                   case .session(let newS) = newRows[i],
                   sessionVisuallyDifferent(oldS, newS) {
                    changedRows.insert(i)
                }
            }
            rows = newRows
            if !changedRows.isEmpty {
                tableView.reloadData(forRowIndexes: changedRows, columnIndexes: IndexSet(integer: 0))
            }
        } else {
            rows = newRows
            tableView.reloadData()
        }
    }

    private func rowStructureMatches(_ a: [SidebarRow], _ b: [SidebarRow]) -> Bool {
        for (ra, rb) in zip(a, b) {
            switch (ra, rb) {
            case (.sectionHeader(let ta), .sectionHeader(let tb)):
                if ta != tb { return false }
            case (.session(let sa), .session(let sb)):
                if sa.id != sb.id { return false }
            default:
                return false
            }
        }
        return true
    }

    private func sessionVisuallyDifferent(_ a: SessionInfo, _ b: SessionInfo) -> Bool {
        a.state != b.state
        || a.name != b.name
        || a.customName != b.customName
        || a.aiName != b.aiName
        || a.hasUnread != b.hasUnread
        || a.starred != b.starred
        || a.branchName != b.branchName
    }

    func setActiveSession(_ sessionId: String) {
        let oldId = activeSessionId
        activeSessionId = sessionId

        // Only reload the old and new active rows instead of the entire table
        var rowsToReload = IndexSet()
        for (i, row) in rows.enumerated() {
            if case .session(let s) = row {
                if s.id == oldId || s.id == sessionId {
                    rowsToReload.insert(i)
                }
            }
        }
        if !rowsToReload.isEmpty {
            tableView.reloadData(forRowIndexes: rowsToReload, columnIndexes: IndexSet(integer: 0))
        }
    }

    func startRename(sessionId: String) {
        guard let idx = rows.firstIndex(where: {
            if case .session(let s) = $0 { return s.id == sessionId }
            return false
        }) else { return }
        if let rv = tableView.view(atColumn: 0, row: idx, makeIfNecessary: false) as? SessionRowView {
            rv.startRename()
        }
    }

    func applyTheme(_ theme: AppTheme) {
        currentTheme = theme
        view.layer?.backgroundColor = theme.sidebarBackground.cgColor
        tableView.reloadData()
        rebuildHeader()
        rebuildFooter()
    }

    @objc private func tableViewClick(_ sender: Any) {
        let row = tableView.clickedRow
        guard row >= 0, case .session(let s) = rows[row] else { return }

        let shiftHeld = NSEvent.modifierFlags.contains(.shift)
        let cmdHeld = NSEvent.modifierFlags.contains(.command)
        if shiftHeld {
            // Shift-click: select range from anchor to clicked row
            if let anchor = lastClickedRow {
                let lo = min(anchor, row)
                let hi = max(anchor, row)
                selectedSessionIds.removeAll()
                for i in lo...hi {
                    if case .session(let rs) = rows[i] {
                        selectedSessionIds.insert(rs.id)
                    }
                }
            } else {
                selectedSessionIds.insert(s.id)
                lastClickedRow = row
            }
            tableView.reloadData()
        } else if cmdHeld {
            // Cmd-click: toggle individual selection
            if selectedSessionIds.contains(s.id) {
                selectedSessionIds.remove(s.id)
            } else {
                selectedSessionIds.insert(s.id)
            }
            lastClickedRow = row
            tableView.reloadData()
        } else {
            selectedSessionIds.removeAll()
            lastClickedRow = row
            tableView.reloadData()
            onSessionSelected?(s.id)
        }
    }

    @objc private func tableViewDoubleClick(_ sender: Any) {
        let row = tableView.clickedRow
        guard row >= 0, case .session(let s) = rows[row] else { return }
        startRename(sessionId: s.id)
    }

    // MARK: - Header

    private func buildHeader() -> NSView {
        let c = NSView()
        c.wantsLayer = true

        // Project folder row — pill-shaped background
        let projectRoot = SessionManager.shared.projectRoot
        let folderName = URL(fileURLWithPath: projectRoot).lastPathComponent

        let projectRow = ClickableView { [weak self] in self?.changeProjectFolder() }
        projectRow.wantsLayer = true
        projectRow.layer?.cornerRadius = 8
        projectRow.layer?.backgroundColor = currentTheme.hoverBackground.cgColor
        projectRow.toolTip = projectRoot

        let projectLabel = NSTextField(labelWithString: folderName)
        projectLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        projectLabel.textColor = currentTheme.sidebarText
        projectLabel.lineBreakMode = .byTruncatingMiddle

        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = currentTheme.sidebarTextSecondary.withAlphaComponent(0.5)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        let chevronConfig = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        chevron.symbolConfiguration = chevronConfig
        NSLayoutConstraint.activate([chevron.widthAnchor.constraint(equalToConstant: 10), chevron.heightAnchor.constraint(equalToConstant: 10)])

        let projStack = NSStackView(views: [projectLabel, chevron])
        projStack.orientation = .horizontal
        projStack.spacing = 6
        projStack.translatesAutoresizingMaskIntoConstraints = false
        projectRow.addSubview(projStack)
        NSLayoutConstraint.activate([
            projStack.topAnchor.constraint(equalTo: projectRow.topAnchor, constant: 6),
            projStack.bottomAnchor.constraint(equalTo: projectRow.bottomAnchor, constant: -6),
            projStack.leadingAnchor.constraint(equalTo: projectRow.leadingAnchor, constant: 10),
            projStack.trailingAnchor.constraint(lessThanOrEqualTo: projectRow.trailingAnchor, constant: -10),
        ])

        // Action buttons — horizontal pill row
        let claudeBtn = makePillButton(
            label: "Claude", shortcut: "\u{2318}T"
        ) { [weak self] in
            self?.onNewClaudeRequested?()
        }
        let deployBtn = makePillButton(
            label: "Deploy", shortcut: "\u{2318}D"
        ) { [weak self] in
            self?.onNewDeployRequested?()
        }
        let shellBtn = makePillButton(
            label: "Shell", shortcut: "\u{21E7}\u{2318}T"
        ) { [weak self] in
            self?.onNewShellRequested?()
        }

        let btnStack = NSStackView(views: [claudeBtn, deployBtn, shellBtn])
        btnStack.orientation = .horizontal
        btnStack.distribution = .fillEqually
        btnStack.spacing = 6

        let vStack = NSStackView(views: [projectRow, btnStack])
        vStack.orientation = .vertical
        vStack.alignment = .leading
        vStack.spacing = 12
        vStack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 8, right: 14)

        vStack.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(vStack)
        NSLayoutConstraint.activate([
            vStack.topAnchor.constraint(equalTo: c.topAnchor),
            vStack.leadingAnchor.constraint(equalTo: c.leadingAnchor),
            vStack.trailingAnchor.constraint(equalTo: c.trailingAnchor),
            vStack.bottomAnchor.constraint(equalTo: c.bottomAnchor),
            projectRow.leadingAnchor.constraint(equalTo: vStack.leadingAnchor, constant: 14),
            projectRow.trailingAnchor.constraint(equalTo: vStack.trailingAnchor, constant: -14),
            btnStack.leadingAnchor.constraint(equalTo: vStack.leadingAnchor, constant: 14),
            btnStack.trailingAnchor.constraint(equalTo: vStack.trailingAnchor, constant: -14),
        ])

        return c
    }

    private func makePillButton(label: String, shortcut: String, action: @escaping () -> Void) -> NSView {
        let container = HoverableButton(action: action)
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.backgroundColor = currentTheme.borderColor.withAlphaComponent(0.4).cgColor
        container.toolTip = "\(label)  \(shortcut)"
        container.hoverColor = currentTheme.borderColor.cgColor
        container.restColor = currentTheme.borderColor.withAlphaComponent(0.4).cgColor

        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: 10, weight: .medium)
        lbl.textColor = currentTheme.sidebarText.withAlphaComponent(0.6)
        lbl.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            lbl.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            lbl.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5),
        ])

        return container
    }

    func changeProject() {
        changeProjectFolder()
    }

    private func changeProjectFolder() {
        let picker = ProjectPickerPanel(
            theme: currentTheme,
            relativeTo: view.window
        ) { [weak self] path in
            SessionManager.shared.setProjectRoot(path)
            self?.rebuildHeader()
        }
        if let window = view.window {
            picker.show(relativeTo: window)
        }
    }

    private func rebuildHeader() {
        guard let old = headerContainer else { return }
        let new = buildHeader()
        new.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(new, positioned: .above, relativeTo: scrollView)
        NSLayoutConstraint.activate([
            new.topAnchor.constraint(equalTo: view.topAnchor),
            new.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            new.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: new.bottomAnchor),
        ])
        old.removeFromSuperview()
        headerContainer = new
    }

    // MARK: - Shortcuts Popover

    @objc private func showShortcutsPopover(_ sender: NSButton) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 240, height: 320)

        let vc = NSViewController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 320))
        container.wantsLayer = true

        let shortcuts: [(String, String)] = [
            ("\u{2318}T", "New Claude Session"),
            ("\u{2318}D", "New Deploy Session"),
            ("\u{21E7}\u{2318}T", "New Shell Tab"),
            ("\u{2318}W", "Close Session"),
            ("\u{2318}R", "Rename Session"),
            ("\u{2318}J", "Toggle Drawer"),
            ("\u{2318}1\u{2013}9", "Switch Session"),
            ("\u{21E7}\u{2318}[", "Previous Session"),
            ("\u{21E7}\u{2318}]", "Next Session"),
            ("\u{2318}+", "Zoom In"),
            ("\u{2318}\u{2013}", "Zoom Out"),
            ("\u{2318}0", "Reset Zoom"),
        ]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7

        let title = NSTextField(labelWithString: "KEYBOARD SHORTCUTS")
        title.font = .systemFont(ofSize: 10, weight: .semibold)
        title.textColor = currentTheme.sidebarTextSecondary
        stack.addArrangedSubview(title)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 2).isActive = true
        stack.addArrangedSubview(spacer)

        for (key, label) in shortcuts {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 10

            let keyLabel = NSTextField(labelWithString: key)
            keyLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            keyLabel.textColor = currentTheme.sidebarText
            keyLabel.alignment = .right
            keyLabel.translatesAutoresizingMaskIntoConstraints = false
            keyLabel.widthAnchor.constraint(equalToConstant: 46).isActive = true

            let descLabel = NSTextField(labelWithString: label)
            descLabel.font = .systemFont(ofSize: 11, weight: .regular)
            descLabel.textColor = currentTheme.sidebarTextSecondary

            row.addArrangedSubview(keyLabel)
            row.addArrangedSubview(descLabel)
            stack.addArrangedSubview(row)
        }

        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
        ])

        vc.view = container
        popover.contentViewController = vc
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxX)
    }

    // MARK: - Footer (Settings)

    private var themePopUp: NSPopUpButton?

    private func makeStyledPopUp(
        items: [(title: String, value: String)],
        selectedValue: String,
        target: AnyObject,
        action: Selector
    ) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.removeAllItems()
        for item in items {
            popup.addItem(withTitle: item.title)
            popup.lastItem?.representedObject = item.value
        }
        if let idx = items.firstIndex(where: { $0.value == selectedValue }) {
            popup.selectItem(at: idx)
        }
        popup.target = target
        popup.action = action
        popup.font = .systemFont(ofSize: 11, weight: .medium)
        popup.contentTintColor = currentTheme.sidebarText
        popup.isBordered = false
        popup.translatesAutoresizingMaskIntoConstraints = false
        for mi in popup.itemArray {
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: currentTheme.sidebarText,
                .font: NSFont.systemFont(ofSize: 11, weight: .medium)
            ]
            mi.attributedTitle = NSAttributedString(string: mi.title, attributes: attrs)
        }
        return popup
    }

    private func makeFooterLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = currentTheme.sidebarTextSecondary.withAlphaComponent(0.4)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func buildFooter() -> NSView {
        let container = NSView()
        container.wantsLayer = true

        // Divider
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = currentTheme.borderColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        // Theme dropdown
        let themeLabel = makeFooterLabel("THEME")
        let themePopup = makeStyledPopUp(
            items: AppTheme.all.map { ($0.name, $0.id) },
            selectedValue: currentTheme.id,
            target: self,
            action: #selector(themeDropdownChanged(_:))
        )
        themePopUp = themePopup

        // Shortcuts button
        let shortcutsBtn = NSButton(title: "Shortcuts", target: self, action: #selector(showShortcutsPopover(_:)))
        shortcutsBtn.bezelStyle = .recessed
        shortcutsBtn.isBordered = false
        shortcutsBtn.font = .systemFont(ofSize: 9, weight: .semibold)
        shortcutsBtn.contentTintColor = currentTheme.sidebarTextSecondary.withAlphaComponent(0.4)
        shortcutsBtn.translatesAutoresizingMaskIntoConstraints = false

        // Indicator style dropdown
        let indicatorLabel = makeFooterLabel("INDICATOR")
        let indicatorPopup = makeStyledPopUp(
            items: IndicatorStyle.allCases.map { ($0.displayName, $0.rawValue) },
            selectedValue: SidebarSettings.indicatorStyle.rawValue,
            target: self,
            action: #selector(indicatorStyleChanged(_:))
        )

        // Density dropdown
        let densityLabel = makeFooterLabel("DENSITY")
        let densityPopup = makeStyledPopUp(
            items: SidebarDensity.allCases.map { ($0.displayName, $0.rawValue) },
            selectedValue: SidebarSettings.density.rawValue,
            target: self,
            action: #selector(densityChanged(_:))
        )

        // Indicator + Density on same row
        let indDensRow = NSView()
        indDensRow.translatesAutoresizingMaskIntoConstraints = false
        indDensRow.addSubview(indicatorLabel)
        indDensRow.addSubview(indicatorPopup)
        indDensRow.addSubview(densityLabel)
        indDensRow.addSubview(densityPopup)
        NSLayoutConstraint.activate([
            indicatorLabel.topAnchor.constraint(equalTo: indDensRow.topAnchor),
            indicatorLabel.leadingAnchor.constraint(equalTo: indDensRow.leadingAnchor, constant: 16),

            indicatorPopup.topAnchor.constraint(equalTo: indicatorLabel.bottomAnchor, constant: 4),
            indicatorPopup.leadingAnchor.constraint(equalTo: indDensRow.leadingAnchor, constant: 10),
            indicatorPopup.bottomAnchor.constraint(equalTo: indDensRow.bottomAnchor),
            indicatorPopup.widthAnchor.constraint(equalTo: indDensRow.widthAnchor, multiplier: 0.5, constant: -12),

            densityLabel.topAnchor.constraint(equalTo: indDensRow.topAnchor),
            densityLabel.leadingAnchor.constraint(equalTo: indDensRow.centerXAnchor, constant: 6),

            densityPopup.topAnchor.constraint(equalTo: densityLabel.bottomAnchor, constant: 4),
            densityPopup.leadingAnchor.constraint(equalTo: indDensRow.centerXAnchor),
            densityPopup.trailingAnchor.constraint(equalTo: indDensRow.trailingAnchor, constant: -10),
            densityPopup.bottomAnchor.constraint(equalTo: indDensRow.bottomAnchor),
        ])

        // Worktree toggle
        let wtLabel = makeFooterLabel("WORKTREE MODE")
        let wtSwitch = NSSwitch()
        wtSwitch.controlSize = .mini
        wtSwitch.state = UserDefaults.standard.bool(forKey: "enableWorktree") ? .on : .off
        wtSwitch.target = self
        wtSwitch.action = #selector(worktreeToggleChanged(_:))
        wtSwitch.translatesAutoresizingMaskIntoConstraints = false
        worktreeToggle = wtSwitch

        // Notification sound toggle
        let nsLabel = makeFooterLabel("NOTIFICATION SOUNDS")
        let nsSwitch = NSSwitch()
        nsSwitch.controlSize = .mini
        nsSwitch.state = UserDefaults.standard.bool(forKey: "enableNotificationSounds") ? .on : .off
        nsSwitch.target = self
        nsSwitch.action = #selector(notifSoundToggleChanged(_:))
        nsSwitch.translatesAutoresizingMaskIntoConstraints = false
        notifSoundToggle = nsSwitch

        container.addSubview(divider)
        container.addSubview(themeLabel)
        container.addSubview(shortcutsBtn)
        container.addSubview(themePopup)
        container.addSubview(indDensRow)
        container.addSubview(wtLabel)
        container.addSubview(wtSwitch)
        container.addSubview(nsLabel)
        container.addSubview(nsSwitch)

        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: container.topAnchor),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            divider.heightAnchor.constraint(equalToConstant: 0.5),

            themeLabel.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 14),
            themeLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            shortcutsBtn.centerYAnchor.constraint(equalTo: themeLabel.centerYAnchor),
            shortcutsBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),

            themePopup.topAnchor.constraint(equalTo: themeLabel.bottomAnchor, constant: 6),
            themePopup.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            themePopup.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),

            indDensRow.topAnchor.constraint(equalTo: themePopup.bottomAnchor, constant: 12),
            indDensRow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            indDensRow.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            wtLabel.topAnchor.constraint(equalTo: indDensRow.bottomAnchor, constant: 12),
            wtLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            wtSwitch.centerYAnchor.constraint(equalTo: wtLabel.centerYAnchor),
            wtSwitch.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),

            nsLabel.topAnchor.constraint(equalTo: wtSwitch.bottomAnchor, constant: 12),
            nsLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            nsSwitch.centerYAnchor.constraint(equalTo: nsLabel.centerYAnchor),
            nsSwitch.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            nsSwitch.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])

        return container
    }

    @objc private func worktreeToggleChanged(_ sender: NSSwitch) {
        UserDefaults.standard.set(sender.state == .on, forKey: "enableWorktree")
    }

    @objc private func notifSoundToggleChanged(_ sender: NSSwitch) {
        UserDefaults.standard.set(sender.state == .on, forKey: "enableNotificationSounds")
    }

    @objc private func themeDropdownChanged(_ sender: NSPopUpButton) {
        guard let themeId = sender.selectedItem?.representedObject as? String else { return }
        let theme = AppTheme.byId(themeId)
        onThemeChanged?(theme)
    }

    @objc private func indicatorStyleChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let style = IndicatorStyle(rawValue: raw) else { return }
        SidebarSettings.indicatorStyle = style
        applySidebarSettings()
    }

    @objc private func densityChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let density = SidebarDensity(rawValue: raw) else { return }
        SidebarSettings.density = density
        applySidebarSettings()
    }

    private func applySidebarSettings() {
        let density = SidebarSettings.density
        tableView.rowHeight = density.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: density.intercellSpacing)
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
        tableView.reloadData()
    }

    private func rebuildFooter() {
        guard let old = footerContainer else { return }
        let new = buildFooter()
        new.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(new)
        NSLayoutConstraint.activate([
            new.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            new.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            new.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: new.topAnchor),
        ])
        old.removeFromSuperview()
        footerContainer = new
    }
}

// MARK: - Table View

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let density = SidebarSettings.density
        switch rows[row] {
        case .sectionHeader: return density.sectionHeaderHeight
        case .session(let s):
            let displayName = s.customName ?? s.aiName ?? s.name
            if let branch = s.branchName, branch != displayName {
                return density.branchRowHeight
            }
            return density.rowHeight
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .sectionHeader(let title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = currentTheme.sidebarTextSecondary.withAlphaComponent(0.5)
            let container = NSView()
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
            ])
            return container
        case .session(let s):
            let rv = SessionRowView(
                session: s,
                isActive: s.id == activeSessionId,
                theme: currentTheme,
                isMultiSelected: selectedSessionIds.contains(s.id)
            )
            rv.onSelect = { [weak self] in self?.onSessionSelected?(s.id) }
            rv.onKill = { [weak self] in
                guard let self = self else { return }
                if !self.selectedSessionIds.isEmpty {
                    // Kill all selected sessions in one batch
                    let idsToKill = self.selectedSessionIds
                    self.selectedSessionIds.removeAll()
                    self.onSessionsKill?(idsToKill)
                } else {
                    self.onSessionKill?(s.id)
                }
            }
            rv.onRename = { [weak self] n in
                self?.isRenaming = false
                SessionManager.shared.renameSession(s.id, name: n)
                self?.forceRefreshSessions()
            }
            rv.onStar = { [weak self] in _ = SessionManager.shared.toggleStar(s.id); self?.forceRefreshSessions() }
            rv.onRenameStarted = { [weak self] in self?.isRenaming = true }
            rv.onRenameEnded = { [weak self] in self?.isRenaming = false }
            return rv
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard case .session(let s) = rows[row] else { return nil }
        let item = NSPasteboardItem()
        item.setString(s.id, forType: sessionDragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard op == .above else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let id = info.draggingPasteboard.string(forType: sessionDragType) else { return false }
        // Work with flat sessions list for reorder
        guard let src = sessions.firstIndex(where: { $0.id == id }) else { return false }
        // Map table row to session index
        var sessionIdx = 0
        for i in 0..<row {
            if case .session = rows[i] { sessionIdx += 1 }
        }
        var dst = min(sessionIdx, sessions.count)
        if src < dst { dst -= 1 }
        guard dst != src else { return false }
        let s = sessions.remove(at: src)
        sessions.insert(s, at: dst)
        SessionManager.shared.reorderSessions(sessions.map { $0.id })
        forceRefreshSessions()
        return true
    }
}

private final class SidebarCallbackButton: NSButton {
    private var callback: (() -> Void)?
    convenience init(title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.callback = action
        self.target = self
        self.action = #selector(clicked)
    }
    @objc private func clicked() { callback?() }
}

private final class HoverableButton: NSView {
    var hoverColor: CGColor?
    var restColor: CGColor?
    private var callback: (() -> Void)?

    convenience init(action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.callback = action
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        ))
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)
    }

    @objc private func handleClick() { callback?() }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = hoverColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = restColor
    }
}
