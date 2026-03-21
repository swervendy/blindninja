import AppKit

/// A quick-open modal for switching project folders, styled like Cursor's project picker.
final class ProjectPickerPanel: NSPanel {
    private var theme: AppTheme
    private let onSelect: (String) -> Void
    private var tableView: NSTableView!
    private var searchField: NSTextField!
    private var filteredRows: [PickerRow] = []
    private var allRows: [PickerRow] = []
    private var selectedIndex: Int = 0

    private enum PickerRow {
        case sectionHeader(String)
        case folder(path: String, icon: String, displayName: String)
        case action(label: String, icon: String, id: String)
    }

    init(theme: AppTheme, relativeTo window: NSWindow?, onSelect: @escaping (String) -> Void) {
        self.theme = theme
        self.onSelect = onSelect

        let width: CGFloat = 380
        let height: CGFloat = 360
        var rect = NSRect(x: 0, y: 0, width: width, height: height)

        if let parentFrame = window?.frame {
            rect.origin.x = parentFrame.midX - width / 2
            rect.origin.y = parentFrame.midY - height / 2 + 60
        }

        super.init(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = false
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = theme.sidebarBackground.cgColor
        container.layer?.cornerRadius = 10
        container.layer?.borderColor = theme.borderColor.cgColor
        container.layer?.borderWidth = 1
        contentView = container

        buildUI(in: container, width: width, height: height)
        buildRows()
        filterRows("")
    }

    // MARK: - Build UI

    private func buildUI(in container: NSView, width: CGFloat, height: CGFloat) {
        // Search field
        let search = NSTextField()
        search.placeholderString = "Open a project..."
        search.font = .systemFont(ofSize: 13, weight: .regular)
        search.isBordered = false
        search.focusRingType = .none
        search.drawsBackground = false
        search.textColor = theme.sidebarText
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false
        searchField = search

        let searchContainer = NSView()
        searchContainer.wantsLayer = true
        searchContainer.translatesAutoresizingMaskIntoConstraints = false

        let searchDivider = NSView()
        searchDivider.wantsLayer = true
        searchDivider.layer?.backgroundColor = theme.borderColor.cgColor
        searchDivider.translatesAutoresizingMaskIntoConstraints = false

        searchContainer.addSubview(search)
        searchContainer.addSubview(searchDivider)
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 14),
            search.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -14),
            search.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            searchDivider.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor),
            searchDivider.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor),
            searchDivider.bottomAnchor.constraint(equalTo: searchContainer.bottomAnchor),
            searchDivider.heightAnchor.constraint(equalToConstant: 0.5),
        ])

        // Table
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        col.resizingMask = .autoresizingMask

        let tv = NSTableView()
        tv.addTableColumn(col)
        tv.headerView = nil
        tv.delegate = self
        tv.dataSource = self
        tv.rowHeight = 30
        tv.selectionHighlightStyle = .none
        tv.backgroundColor = .clear
        tv.intercellSpacing = NSSize(width: 0, height: 0)
        tableView = tv

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.scrollerStyle = .overlay

        container.addSubview(searchContainer)
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            searchContainer.topAnchor.constraint(equalTo: container.topAnchor),
            searchContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            searchContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            searchContainer.heightAnchor.constraint(equalToConstant: 40),
            scroll.topAnchor.constraint(equalTo: searchContainer.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: - Data

    private func buildRows() {
        var rows: [PickerRow] = []

        let recents = ProjectPickerPanel.recentProjects()
        if !recents.isEmpty {
            rows.append(.sectionHeader("Recents"))
            for path in recents {
                let display = Self.abbreviatePath(path)
                rows.append(.folder(path: path, icon: "folder", displayName: display))
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        rows.append(.sectionHeader("Quick Access"))
        rows.append(.folder(path: home, icon: "house", displayName: "Home"))

        let desktop = (home as NSString).appendingPathComponent("Desktop")
        if FileManager.default.fileExists(atPath: desktop) {
            rows.append(.folder(path: desktop, icon: "folder", displayName: "~/Desktop"))
        }
        let documents = (home as NSString).appendingPathComponent("Documents")
        if FileManager.default.fileExists(atPath: documents) {
            rows.append(.folder(path: documents, icon: "doc.text", displayName: "~/Documents"))
        }
        let projects = (home as NSString).appendingPathComponent("Documents/Projects")
        if FileManager.default.fileExists(atPath: projects) {
            rows.append(.folder(path: projects, icon: "hammer", displayName: "~/Documents/Projects"))
        }

        rows.append(.sectionHeader(""))
        rows.append(.action(label: "Open folder...", icon: "folder.badge.plus", id: "open"))

        allRows = rows
    }

    private func filterRows(_ query: String) {
        if query.isEmpty {
            filteredRows = allRows
        } else {
            let q = query.lowercased()
            filteredRows = allRows.filter { row in
                switch row {
                case .sectionHeader: return false
                case .folder(_, _, let name): return name.lowercased().contains(q)
                case .action(let label, _, _): return label.lowercased().contains(q)
                }
            }
        }
        tableView.reloadData()
        selectedIndex = firstSelectableIndex()
        tableView.reloadData()
    }

    private func firstSelectableIndex() -> Int {
        for (i, row) in filteredRows.enumerated() {
            if case .sectionHeader = row { continue }
            return i
        }
        return 0
    }

    // MARK: - Recent Projects

    private static let recentsKey = "recentProjectRoots"
    private static let maxRecents = 5

    static func recentProjects() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
    }

    static func addRecentProject(_ path: String) {
        var recents = recentProjects()
        recents.removeAll { $0 == path }
        recents.insert(path, at: 0)
        if recents.count > maxRecents {
            recents = Array(recents.prefix(maxRecents))
        }
        UserDefaults.standard.set(recents, forKey: recentsKey)
    }

    static func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Actions

    private func selectCurrentRow() {
        guard selectedIndex >= 0 && selectedIndex < filteredRows.count else { return }
        let row = filteredRows[selectedIndex]
        switch row {
        case .sectionHeader: break
        case .folder(let path, _, _):
            ProjectPickerPanel.addRecentProject(path)
            onSelect(path)
            dismiss()
        case .action(_, _, let id):
            if id == "open" {
                dismiss()
                openFolderPanel()
            }
        }
    }

    private func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: SessionManager.shared.projectRoot)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let path = url.path
            ProjectPickerPanel.addRecentProject(path)
            self?.onSelect(path)
        }
    }

    func dismiss() {
        orderOut(nil)
        parent?.removeChildWindow(self)
    }

    // MARK: - Key handling

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            dismiss()
        case 125: // Down arrow
            moveSelection(by: 1)
        case 126: // Up arrow
            moveSelection(by: -1)
        case 36: // Return
            selectCurrentRow()
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }

    private func moveSelection(by delta: Int) {
        var next = selectedIndex + delta
        // Skip section headers
        while next >= 0 && next < filteredRows.count {
            if case .sectionHeader = filteredRows[next] {
                next += delta
                continue
            }
            break
        }
        guard next >= 0 && next < filteredRows.count else { return }
        selectedIndex = next
        tableView.reloadData()
        tableView.scrollRowToVisible(next)
    }

    // MARK: - Show

    func show(relativeTo window: NSWindow) {
        window.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(searchField)
    }
}

// MARK: - Table View

extension ProjectPickerPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { filteredRows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch filteredRows[row] {
        case .sectionHeader(let t): return t.isEmpty ? 8 : 26
        case .folder: return 30
        case .action: return 30
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let pickerRow = filteredRows[row]
        let isSelected = row == selectedIndex

        switch pickerRow {
        case .sectionHeader(let title):
            let container = NSView()
            if !title.isEmpty {
                let label = NSTextField(labelWithString: title)
                label.font = .systemFont(ofSize: 10, weight: .semibold)
                label.textColor = theme.sidebarTextSecondary.withAlphaComponent(0.4)
                label.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
                    label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
                ])
            }
            return container

        case .folder(_, let icon, let displayName):
            return makeRow(icon: icon, label: displayName, isSelected: isSelected, row: row)

        case .action(let label, let icon, _):
            return makeRow(icon: icon, label: label, isSelected: isSelected, row: row)
        }
    }

    private func makeRow(icon: String, label: String, isSelected: Bool, row: Int) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        if isSelected {
            container.layer?.backgroundColor = theme.selectedBackground.cgColor
        }

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        iconView.contentTintColor = isSelected ? theme.sidebarText : theme.sidebarTextSecondary
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        iconView.symbolConfiguration = config

        let textLabel = NSTextField(labelWithString: label)
        textLabel.font = .systemFont(ofSize: 12, weight: isSelected ? .medium : .regular)
        textLabel.textColor = isSelected ? theme.sidebarText : theme.sidebarText.withAlphaComponent(0.8)
        textLabel.lineBreakMode = .byTruncatingMiddle

        let stack = NSStackView(views: [iconView, textLabel])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        // Track click
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect],
            owner: container
        )
        container.addTrackingArea(trackingArea)

        return container
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .sectionHeader = filteredRows[row] { return false }
        selectedIndex = row
        selectCurrentRow()
        return false
    }
}

// MARK: - Search Field Delegate

extension ProjectPickerPanel: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        filterRows(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(moveDown(_:)) {
            moveSelection(by: 1)
            return true
        } else if commandSelector == #selector(moveUp(_:)) {
            moveSelection(by: -1)
            return true
        } else if commandSelector == #selector(insertNewline(_:)) {
            selectCurrentRow()
            return true
        } else if commandSelector == #selector(cancelOperation(_:)) {
            dismiss()
            return true
        }
        return false
    }
}
