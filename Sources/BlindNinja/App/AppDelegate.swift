import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    var statusItem: NSStatusItem?

    // Track theme changes
    var currentTheme: AppTheme = .blueTitanium {
        didSet { applyThemeToAll() }
    }

    /// The split VC for the currently active (key) window.
    private var activeSplitVC: MainSplitViewController? {
        let keyWindow = NSApp.keyWindow ?? windows.last
        return keyWindow?.contentViewController as? MainSplitViewController
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load saved theme
        if let savedId = UserDefaults.standard.string(forKey: "theme") {
            currentTheme = AppTheme.byId(savedId)
        }

        // Set app icon from bundled PNG
        let iconPath = "/Users/aaron/Documents/Projects/blind-ninja-app/src-tauri/icons/icon.png"
        if let icon = NSImage(contentsOfFile: iconPath) {
            NSApp.applicationIconImage = icon
        }

        // Build the menu bar
        buildMainMenu()

        // Set up status bar item
        setupStatusItem()

        // Create the first window
        let window = createWindow()

        // Restore persisted sessions, or create a fresh one
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            SessionManager.shared.restoreSessions()

            ProjectPickerPanel.addRecentProject(SessionManager.shared.projectRoot)
            if SessionManager.shared.listSessions().isEmpty {
                _ = try? SessionManager.shared.createSession(command: "claude")
            }
            (window.contentViewController as? MainSplitViewController)?.selectFirstSession()

            // Start periodic auto-save
            SessionManager.shared.startAutoSave()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SessionManager.shared.saveAllSessions()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Window Management

    @discardableResult
    func createWindow() -> NSWindow {
        let splitVC = MainSplitViewController()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Blind Ninja"
        window.minSize = NSSize(width: 400, height: 300)
        window.contentViewController = splitVC
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = currentTheme.terminal.background
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.delegate = self

        // Offset from existing windows
        if let last = windows.last {
            let origin = last.frame.origin
            window.setFrameOrigin(NSPoint(x: origin.x + 30, y: origin.y - 30))
        } else {
            window.center()
        }

        windows.append(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        splitVC.applyTheme(currentTheme)

        return window
    }

    // MARK: - Menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Blind Ninja", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Blind Ninja", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow), keyEquivalent: "n")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "New Claude Session", action: #selector(newClaudeSession), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "New Shell Session", action: #selector(newShellSession), keyEquivalent: "T")
        fileMenu.addItem(withTitle: "New Deploy Session", action: #selector(newDeploySession), keyEquivalent: "d")

        let closeItem = NSMenuItem(title: "Close Session", action: #selector(closeCurrentSession), keyEquivalent: "w")
        fileMenu.addItem(closeItem)

        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Rename Session", action: #selector(renameCurrentSession), keyEquivalent: "r")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Open Project...", action: #selector(openProjectPicker), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "b")
        fileMenu.addItem(withTitle: "Toggle Drawer", action: #selector(toggleDrawer), keyEquivalent: "j")

        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // View menu
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "=")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Reset Zoom", action: #selector(zoomReset), keyEquivalent: "0")
        viewMenu.addItem(.separator())

        // Theme submenu
        let themeMenu = NSMenu(title: "Theme")
        for theme in AppTheme.all {
            let item = NSMenuItem(title: theme.name, action: #selector(changeTheme(_:)), keyEquivalent: "")
            item.representedObject = theme.id
            if theme.id == currentTheme.id {
                item.state = .on
            }
            themeMenu.addItem(item)
        }
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeItem.submenu = themeMenu
        viewMenu.addItem(themeItem)

        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window menu (for session switching Cmd+1-9)
        let windowMenu = NSMenu(title: "Window")
        for i in 1...9 {
            let item = NSMenuItem(
                title: "Session \(i)",
                action: #selector(switchToSessionByIndex(_:)),
                keyEquivalent: "\(i)"
            )
            item.tag = i
            windowMenu.addItem(item)
        }
        windowMenu.addItem(.separator())

        let prevItem = NSMenuItem(title: "Previous Session", action: #selector(previousSession), keyEquivalent: "[")
        prevItem.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(prevItem)

        let nextItem = NSMenuItem(title: "Next Session", action: #selector(nextSession), keyEquivalent: "]")
        nextItem.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(nextItem)

        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        // Edit menu (for copy/paste in terminal)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    // MARK: - Actions (routed to active window)

    @objc private func newWindow() {
        let window = createWindow()
        // Create a fresh Claude session in the new window
        _ = try? SessionManager.shared.createSession(command: "claude")
        (window.contentViewController as? MainSplitViewController)?.selectLastSession()
    }

    @objc private func newClaudeSession() {
        _ = try? SessionManager.shared.createSession(command: "claude")
        activeSplitVC?.selectLastSession()
    }

    @objc private func newShellSession() {
        activeSplitVC?.terminalHost.drawer.createNewShellTab()
    }

    @objc private func newDeploySession() {
        _ = try? SessionManager.shared.createSession(
            name: "Deploy",
            command: "claude --dangerously-skip-permissions"
        )
        activeSplitVC?.selectLastSession()
    }

    @objc private func closeCurrentSession() {
        activeSplitVC?.killCurrentSession()
    }

    @objc private func renameCurrentSession() {
        activeSplitVC?.renameCurrentSession()
    }

    @objc private func openProjectPicker() {
        activeSplitVC?.sidebar.changeProject()
    }

    @objc private func toggleSidebar() {
        activeSplitVC?.toggleSidebar()
    }

    @objc private func toggleDrawer() {
        activeSplitVC?.toggleDrawer()
    }

    @objc private func switchToSessionByIndex(_ sender: NSMenuItem) {
        activeSplitVC?.selectSessionByIndex(sender.tag - 1)
    }

    @objc private func previousSession() {
        activeSplitVC?.selectPreviousSession()
    }

    @objc private func nextSession() {
        activeSplitVC?.selectNextSession()
    }

    @objc private func zoomIn() {
        activeSplitVC?.terminalHost.adjustFontSize(delta: 1)
    }

    @objc private func zoomOut() {
        activeSplitVC?.terminalHost.adjustFontSize(delta: -1)
    }

    @objc private func zoomReset() {
        activeSplitVC?.terminalHost.resetFontSize()
    }

    @objc private func changeTheme(_ sender: NSMenuItem) {
        guard let themeId = sender.representedObject as? String else { return }
        currentTheme = AppTheme.byId(themeId)
        UserDefaults.standard.set(themeId, forKey: "theme")
    }

    // MARK: - Theme

    private func applyThemeToAll() {
        for window in windows {
            window.backgroundColor = currentTheme.terminal.background
            (window.contentViewController as? MainSplitViewController)?.applyTheme(currentTheme)
        }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            if let appIcon = NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) {
                let size = NSSize(width: 18, height: 18)
                let resized = NSImage(size: size)
                resized.lockFocus()
                appIcon.draw(in: NSRect(origin: .zero, size: size),
                            from: NSRect(origin: .zero, size: appIcon.size),
                            operation: .sourceOver, fraction: 1.0)
                resized.unlockFocus()
                resized.isTemplate = false
                button.image = resized
                button.imagePosition = .imageLeft
            }
            button.title = ""
            button.action = #selector(statusItemClicked)
            button.target = self
        }

        NotificationCenter.default.addObserver(
            forName: .sessionsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateStatusBadge()
        }
    }

    @objc private func statusItemClicked() {
        if let window = NSApp.keyWindow ?? windows.last {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateStatusBadge() {
        let sessions = SessionManager.shared.listSessions()
        let waitingCount = sessions.filter { $0.state == .waiting || $0.state == .blocked }.count
        if waitingCount > 0 {
            statusItem?.button?.title = " \(waitingCount)"
            NSApp.dockTile.badgeLabel = "\(waitingCount)"
        } else {
            statusItem?.button?.title = ""
            NSApp.dockTile.badgeLabel = nil
        }
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows.removeAll { $0 === window }
    }
}
