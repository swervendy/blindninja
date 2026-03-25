import AppKit
import SwiftTerm
import UniformTypeIdentifiers

/// Bottom drawer panel with tabbed shell sessions and file editor tabs.
final class DrawerViewController: NSViewController, TerminalViewDelegate {
    var onSessionClosed: ((String) -> Void)?

    private var tabs: [String] = []  // session IDs for shell tabs
    private var activeTabIndex: Int?
    private var drawerTerminalViews: [String: TerminalView] = [:]
    private var currentTheme: AppTheme = .blueTitanium
    private var fontSize: CGFloat = 12

    // Env file overlay (separate from tabs)
    private var envEditorView: FileEditorView?
    private var envFilePath: String?
    private var isEnvShowing = false
    private var envBtn: DrawerCallbackButton!

    private var handleBar: DragHandleView!
    private let tabBar = NSStackView()
    private let contentContainer = NSView()
    private var activeContentView: NSView?
    /// Track last sent PTY dimensions to avoid redundant resize calls during drag-to-resize
    private var lastResizeCols: Int = 0
    private var lastResizeRows: Int = 0

    private var heightConstraint: NSLayoutConstraint!
    private(set) var expanded = false
    private let collapsedHeight: CGFloat = 28
    private let defaultExpandedHeight: CGFloat = 200
    private var lastExpandedHeight: CGFloat = 200

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Handle bar — custom view with mouse tracking for drag-to-resize
        handleBar = DragHandleView()
        handleBar.wantsLayer = true
        handleBar.layer?.backgroundColor = currentTheme.headerBackground.cgColor
        handleBar.onDrag = { [weak self] delta in self?.handleDrag(delta) }
        handleBar.onDragEnd = { [weak self] in self?.handleDragEnd() }
        handleBar.onClick = { [weak self] in self?.toggle() }

        // Drag indicator pill
        let dragIndicator = NSView()
        dragIndicator.wantsLayer = true
        dragIndicator.layer?.backgroundColor = currentTheme.sidebarTextSecondary.withAlphaComponent(0.3).cgColor
        dragIndicator.layer?.cornerRadius = 1.5

        // Tab bar
        tabBar.orientation = .horizontal
        tabBar.spacing = 0
        tabBar.alignment = .centerY

        // ".env" button — toggles env file overlay
        envBtn = DrawerCallbackButton(title: ".env") { [weak self] in
            self?.toggleEnvFile()
        }
        envBtn.bezelStyle = .recessed
        envBtn.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        envBtn.isBordered = false
        envBtn.contentTintColor = currentTheme.sidebarTextSecondary

        // "+" button
        let addBtn = DrawerCallbackButton(title: "+") { [weak self] in
            self?.createNewShellTab()
        }
        addBtn.bezelStyle = .recessed
        addBtn.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        addBtn.isBordered = false
        addBtn.contentTintColor = currentTheme.sidebarTextSecondary

        dragIndicator.translatesAutoresizingMaskIntoConstraints = false
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        envBtn.translatesAutoresizingMaskIntoConstraints = false
        addBtn.translatesAutoresizingMaskIntoConstraints = false
        handleBar.addSubview(dragIndicator)
        handleBar.addSubview(tabBar)
        handleBar.addSubview(envBtn)
        handleBar.addSubview(addBtn)

        NSLayoutConstraint.activate([
            dragIndicator.centerXAnchor.constraint(equalTo: handleBar.centerXAnchor),
            dragIndicator.topAnchor.constraint(equalTo: handleBar.topAnchor, constant: 4),
            dragIndicator.widthAnchor.constraint(equalToConstant: 36),
            dragIndicator.heightAnchor.constraint(equalToConstant: 3),

            tabBar.leadingAnchor.constraint(equalTo: handleBar.leadingAnchor, constant: 8),
            tabBar.centerYAnchor.constraint(equalTo: handleBar.centerYAnchor, constant: 2),
            tabBar.trailingAnchor.constraint(lessThanOrEqualTo: envBtn.leadingAnchor, constant: -4),

            envBtn.trailingAnchor.constraint(equalTo: addBtn.leadingAnchor, constant: -6),
            envBtn.centerYAnchor.constraint(equalTo: handleBar.centerYAnchor, constant: 2),

            addBtn.trailingAnchor.constraint(equalTo: handleBar.trailingAnchor, constant: -8),
            addBtn.centerYAnchor.constraint(equalTo: handleBar.centerYAnchor, constant: 2),
        ])

        // Content container (holds terminal views or file editor views)
        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = currentTheme.terminal.background.cgColor
        contentContainer.layer?.masksToBounds = true
        contentContainer.isHidden = true

        // Main layout
        handleBar.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(handleBar)
        view.addSubview(contentContainer)

        heightConstraint = view.heightAnchor.constraint(equalToConstant: collapsedHeight)
        heightConstraint.isActive = true

        NSLayoutConstraint.activate([
            handleBar.topAnchor.constraint(equalTo: view.topAnchor),
            handleBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            handleBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            handleBar.heightAnchor.constraint(equalToConstant: 28),

            contentContainer.topAnchor.constraint(equalTo: handleBar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Top border
        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = currentTheme.borderColor.cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(border)
        NSLayoutConstraint.activate([
            border.topAnchor.constraint(equalTo: view.topAnchor),
            border.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    // MARK: - Public

    func resignActiveTerminalFocus() {
        if let idx = activeTabIndex, idx < tabs.count,
           let termView = drawerTerminalViews[tabs[idx]] {
            termView.hasFocus = false
        }
    }

    func startRenameActiveTab() {
        guard let index = activeTabIndex, index < tabBar.arrangedSubviews.count else { return }
        (tabBar.arrangedSubviews[index] as? DrawerTab)?.startRename()
    }

    func addSession(_ sessionId: String) {
        if tabs.contains(sessionId) { return }
        tabs.append(sessionId)
        let index = tabs.count - 1
        selectTab(at: index)
        if !expanded { toggle() }
    }

    func toggle() {
        if expanded {
            lastExpandedHeight = heightConstraint.constant
        }
        expanded.toggle()
        heightConstraint.constant = expanded ? lastExpandedHeight : collapsedHeight
        contentContainer.isHidden = !expanded

        if expanded && tabs.isEmpty {
            createNewShellTab()
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            view.superview?.layoutSubtreeIfNeeded()
        }
    }

    func applyTheme(_ theme: AppTheme) {
        currentTheme = theme
        handleBar.layer?.backgroundColor = theme.headerBackground.cgColor
        contentContainer.layer?.backgroundColor = theme.terminal.background.cgColor
        for (_, tv) in drawerTerminalViews {
            applyTerminalTheme(tv, theme: theme)
        }
        envEditorView?.applyTheme(theme)
        updateEnvButtonStyle()
        rebuildTabs()
    }

    // MARK: - Drag-to-resize

    private func handleDrag(_ deltaY: CGFloat) {
        // deltaY > 0 means mouse moved up → drawer should grow
        let maxHeight = (view.superview?.bounds.height ?? 600) * 0.75
        let newHeight = max(collapsedHeight, min(maxHeight, heightConstraint.constant + deltaY))
        heightConstraint.constant = newHeight

        if newHeight > collapsedHeight + 20 && !expanded {
            expanded = true
            contentContainer.isHidden = false
            if tabs.isEmpty { createNewShellTab() }
        }
    }

    private func handleDragEnd() {
        if heightConstraint.constant < collapsedHeight + 40 {
            heightConstraint.constant = collapsedHeight
            expanded = false
            contentContainer.isHidden = true
        } else if heightConstraint.constant < 100 {
            heightConstraint.constant = 120
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            view.superview?.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - Tab management

    func createNewShellTab() {
        guard let session = try? SessionManager.shared.createSession() else { return }
        addSession(session.id)
    }

    // MARK: - Env file overlay

    private func toggleEnvFile() {
        if isEnvShowing {
            hideEnvOverlay()
            return
        }

        let root = SessionManager.shared.projectRoot
        let candidates = [".env", ".env.local", ".env.development", ".env.development.local"]
        let found = candidates.first { name in
            FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(name))
        }

        if let envName = found {
            let envPath = (root as NSString).appendingPathComponent(envName)
            showEnvOverlay(path: envPath)
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath: root)
            panel.allowedContentTypes = [.plainText, .data]
            panel.title = "Select .env file"
            panel.begin { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                self?.showEnvOverlay(path: url.path)
            }
        }
    }

    private func showEnvOverlay(path: String) {
        // Reuse or create editor
        if envFilePath != path {
            envEditorView?.removeFromSuperview()
            envEditorView = nil
        }

        if envEditorView == nil {
            let editor = FileEditorView(filePath: path, theme: currentTheme)
            editor.onDirtyChange = { [weak self] in self?.updateEnvButtonStyle() }
            envEditorView = editor
            envFilePath = path
        }

        guard let editor = envEditorView else { return }
        editor.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            editor.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])

        // Hide the active terminal (but keep it in memory)
        activeContentView?.isHidden = true
        isEnvShowing = true
        updateEnvButtonStyle()
        editor.focus()

        if !expanded { toggle() }
    }

    private func hideEnvOverlay() {
        envEditorView?.removeFromSuperview()
        isEnvShowing = false
        activeContentView?.isHidden = false
        updateEnvButtonStyle()

        // Refocus the terminal
        if let tv = activeContentView {
            view.window?.makeFirstResponder(tv)
        }
    }

    private func updateEnvButtonStyle() {
        if isEnvShowing {
            envBtn.wantsLayer = true
            envBtn.layer?.cornerRadius = 4
            envBtn.layer?.backgroundColor = currentTheme.selectedBackground.cgColor
            envBtn.contentTintColor = currentTheme.sidebarText
        } else {
            envBtn.layer?.backgroundColor = nil
            envBtn.contentTintColor = currentTheme.sidebarTextSecondary
        }
    }

    // MARK: - Tab management (shell tabs only)

    private func selectTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }

        // If already active (and not showing env), just ensure focus — don't rebuild
        if index == activeTabIndex && !isEnvShowing {
            if let termView = activeContentView {
                view.window?.makeFirstResponder(termView)
            }
            return
        }

        activeContentView?.removeFromSuperview()
        activeContentView = nil
        activeTabIndex = index
        // Reset resize cache so we send correct dimensions for the new tab
        lastResizeCols = 0
        lastResizeRows = 0

        // Hide env overlay when switching to a shell tab
        if isEnvShowing { hideEnvOverlay() }

        let sessionId = tabs[index]
        let termView: TerminalView
        if let existing = drawerTerminalViews[sessionId] {
            termView = existing
        } else {
            termView = createTerminalView(for: sessionId)
            drawerTerminalViews[sessionId] = termView
            SessionManager.shared.registerTerminalView(termView, for: sessionId)
        }

        // Frame-based layout — SwiftTerm breaks with autolayout constraints
        let inset = NSEdgeInsets(top: 12, left: 8, bottom: 2, right: 4)
        let frame = contentContainer.bounds.insetBy(inset)
        // Guard against zero/negative frame when container hasn't been laid out yet
        if frame.width > 0 && frame.height > 0 {
            termView.frame = frame
        }
        termView.autoresizingMask = [.width, .height]
        contentContainer.addSubview(termView)
        activeContentView = termView
        view.window?.makeFirstResponder(termView)

        rebuildTabs()
    }

    private func closeTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        let sessionId = tabs[index]

        tabs.remove(at: index)
        drawerTerminalViews.removeValue(forKey: sessionId)
        onSessionClosed?(sessionId)

        if activeTabIndex == index {
            activeContentView?.removeFromSuperview()
            activeContentView = nil
            activeTabIndex = nil

            if !tabs.isEmpty {
                let newIndex = min(index, tabs.count - 1)
                selectTab(at: newIndex)
            }
        } else if let active = activeTabIndex, active > index {
            activeTabIndex = active - 1
        }

        rebuildTabs()
        if tabs.isEmpty && expanded { toggle() }
    }

    private func rebuildTabs() {
        tabBar.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for (index, sessionId) in tabs.enumerated() {
            let isActive = index == activeTabIndex && !isEnvShowing
            let title = SessionManager.shared.getSessionName(sessionId) ?? "Shell"

            let tabView = DrawerTab(
                title: title,
                isActive: isActive,
                theme: currentTheme,
                onSelect: { [weak self] in self?.selectTab(at: index) },
                onClose: { [weak self] in self?.closeTab(at: index) },
                onRename: { [weak self] newName in
                    SessionManager.shared.renameSession(sessionId, name: newName)
                    self?.rebuildTabs()
                }
            )
            tabBar.addArrangedSubview(tabView)
        }
    }

    // MARK: - Terminal helpers

    private func createTerminalView(for sessionId: String) -> TerminalView {
        let termView = TerminalView(frame: contentContainer.bounds)
        termView.terminalDelegate = self
        termView.autoresizingMask = [.width, .height]

        let font = NSFont(name: "SF Mono", size: fontSize)
            ?? NSFont(name: "Menlo", size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        termView.font = font
        termView.optionAsMetaKey = true
        applyTerminalTheme(termView, theme: currentTheme)

        DispatchQueue.main.async {
            TerminalHostViewController.hideScroller(in: termView)
        }

        return termView
    }

    private func applyTerminalTheme(_ termView: TerminalView, theme: AppTheme) {
        let tc = theme.terminal
        let palette = tc.ansi.map { mkColor($0) }
        if palette.count == 16 { termView.installColors(palette) }
        termView.nativeBackgroundColor = tc.background
        termView.nativeForegroundColor = tc.foreground
    }

    private func mkColor(_ nsColor: NSColor) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let c = nsColor.usingColorSpace(.sRGB) ?? nsColor
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return Color(red: UInt16(r * 65535), green: UInt16(g * 65535), blue: UInt16(b * 65535))
    }

    private var activeTerminalSessionId: String? {
        guard let index = activeTabIndex, index < tabs.count else { return nil }
        return tabs[index]
    }

    // MARK: - TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let sid = activeTerminalSessionId else { return }
        guard newCols != lastResizeCols || newRows != lastResizeRows else { return }
        lastResizeCols = newCols
        lastResizeRows = newRows
        SessionManager.shared.resizeSession(sid, cols: UInt16(newCols), rows: UInt16(newRows))
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let sid = activeTerminalSessionId else { return }
        // Translate kitty keypad codes to standard CSI (same issue as main terminal)
        if data.count >= 5 && data.count <= 10 && data.first == 0x1b,
           let str = String(bytes: data, encoding: .utf8),
           let replacement = TerminalHostViewController.kittyCsiReplacements[str] {
            SessionManager.shared.writeToSession(sid, data: Data(replacement))
            return
        }
        SessionManager.shared.writeToSession(sid, data: Data(data))
    }
    func scrolled(source: TerminalView, position: Double) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(content, forType: .string)
    }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Drag Handle View (mouse tracking for resize)

final class DragHandleView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    var onClick: (() -> Void)?

    private var isDragging = false
    private var lastY: CGFloat = 0
    private var didDrag = false

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        didDrag = false
        lastY = event.locationInWindow.y
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let currentY = event.locationInWindow.y
        let delta = currentY - lastY
        if abs(currentY - lastY) > 4 { didDrag = true }
        guard didDrag else { return }
        onDrag?(delta)
        lastY = currentY
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        if didDrag {
            onDragEnd?()
        } else {
            onClick?()
        }
    }
}

// MARK: - Drawer Tab

private final class DrawerTab: NSView, NSTextFieldDelegate {
    private var selectAction: (() -> Void)?
    private var onRename: ((String) -> Void)?
    private var label: NSTextField!
    private var renameField: NSTextField?
    private var theme: AppTheme
    private var isEndingRename = false

    init(title: String, isActive: Bool, theme: AppTheme,
         onSelect: @escaping () -> Void, onClose: @escaping () -> Void,
         onRename: @escaping (String) -> Void) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        self.selectAction = onSelect
        self.onRename = onRename

        if isActive {
            layer?.backgroundColor = theme.terminal.background.cgColor
            layer?.borderWidth = 1
            layer?.borderColor = theme.borderColor.cgColor
        }
        layer?.cornerRadius = 5
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]

        let label = NSTextField(labelWithString: title)
        label.font = .monospacedSystemFont(ofSize: 11, weight: isActive ? .medium : .regular)
        label.textColor = isActive ? theme.sidebarText : theme.sidebarTextSecondary
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        self.label = label

        let closeBtn = DrawerCallbackButton(title: "\u{2715}", action: onClose)
        closeBtn.bezelStyle = .recessed
        closeBtn.font = .systemFont(ofSize: 9, weight: .medium)
        closeBtn.isBordered = false
        closeBtn.contentTintColor = theme.sidebarTextSecondary
        closeBtn.alphaValue = isActive ? 0.7 : 0.3

        let stack = NSStackView(views: [label, closeBtn])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 6)

        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 26),
        ])

    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            startRename()
        } else {
            selectAction?()
        }
    }

    func startRename() {
        guard renameField == nil else { return }
        isEndingRename = false
        let field = NSTextField(string: label.stringValue)
        field.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        field.textColor = theme.sidebarText
        field.backgroundColor = theme.terminal.background
        field.drawsBackground = true
        field.isBordered = true
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
        // Keep label's space so the tab doesn't collapse, just hide the text
        label.alphaValue = 0
        renameField = field
        window?.makeFirstResponder(field)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Rename", action: #selector(ctxRename), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

    @objc private func ctxRename() { startRename() }

    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        guard !isEndingRename else { return true }
        isEndingRename = true
        let newName = fieldEditor.string.trimmingCharacters(in: .whitespaces)
        label.alphaValue = 1
        renameField?.removeFromSuperview()
        renameField = nil
        if !newName.isEmpty {
            label.stringValue = newName
            onRename?(newName)
        }
        return true
    }
}

// MARK: - CallbackButton (drawer-local)

private final class DrawerCallbackButton: NSButton {
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
