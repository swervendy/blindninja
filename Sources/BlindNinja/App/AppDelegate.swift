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

        // Set app icon — add transparent padding so the macOS dock badge
        // doesn't bleed over the artwork. Apple's icon grid puts art in
        // the center ~80% of the canvas with transparent margins.
        if let rawIcon = loadAppIcon() {
            let padded = Self.padIcon(rawIcon, insetFraction: 0.10)
            NSApp.applicationIconImage = padded
        }

        // Build the menu bar
        buildMainMenu()

        // Set up status bar item
        setupStatusItem()

        // Create the first window
        let window = createWindow()

        // Restore persisted sessions, or create a fresh one
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let splitVC = window.contentViewController as? MainSplitViewController
            SessionManager.shared.restoreSessions()

            // Adopt all restored sessions into the first window
            for session in SessionManager.shared.listSessions() {
                splitVC?.adoptSession(session.id)
            }

            ProjectPickerPanel.addRecentProject(SessionManager.shared.projectRoot)
            if SessionManager.shared.listSessions().isEmpty {
                _ = try? splitVC?.createOwnedSession(command: "claude")
            }
            splitVC?.selectFirstSession()

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

        viewMenu.addItem(.separator())
        let notifSoundItem = NSMenuItem(title: "Toggle Notification Sounds", action: #selector(toggleNotificationSounds), keyEquivalent: "n")
        notifSoundItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(notifSoundItem)

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

        let prevItem2 = NSMenuItem(title: "Previous Session (Alt)", action: #selector(previousSession), keyEquivalent: "i")
        prevItem2.keyEquivalentModifierMask = [.command]
        windowMenu.addItem(prevItem2)

        let nextItem2 = NSMenuItem(title: "Next Session (Alt)", action: #selector(nextSession), keyEquivalent: "u")
        nextItem2.keyEquivalentModifierMask = [.command]
        windowMenu.addItem(nextItem2)


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
        let splitVC = window.contentViewController as? MainSplitViewController
        _ = try? splitVC?.createOwnedSession(command: "claude")
        splitVC?.selectLastSession()
    }

    @objc private func newClaudeSession() {
        _ = try? activeSplitVC?.createOwnedSession(command: "claude")
        activeSplitVC?.selectLastSession()
    }

    @objc private func newShellSession() {
        activeSplitVC?.terminalHost.drawer.createNewShellTab()
    }

    @objc private func newDeploySession() {
        _ = try? activeSplitVC?.createOwnedSession(
            name: "Deploy",
            command: SessionManager.shared.buildDeployCommand()
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

    @objc private func toggleNotificationSounds() {
        let current = UserDefaults.standard.bool(forKey: "enableNotificationSounds")
        UserDefaults.standard.set(!current, forKey: "enableNotificationSounds")
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
            button.image = Self.makeMenuBarIcon()
            button.imagePosition = .imageLeft
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
        let menu = NSMenu()

        // Session list (exclude shell sessions, they live in the drawer)
        let allSessions = SessionManager.shared.listSessions()
        let sessions = allSessions.filter { $0.sessionType != .shell }
        if sessions.isEmpty {
            let item = NSMenuItem(title: "No Sessions", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for (index, session) in sessions.enumerated() {
                let stateEmoji: String
                switch session.state {
                case .working:  stateEmoji = "\u{1F7E1}"  // yellow circle — working
                case .waiting:  stateEmoji = "\u{1F534}"  // red circle — needs input
                case .blocked:  stateEmoji = "\u{1F534}"  // red circle — needs approval
                case .idle:     stateEmoji = "\u{1F7E2}"  // green circle — idle
                case .new:      stateEmoji = "\u{26AA}"    // white circle
                }
                let title = "\(stateEmoji) \(session.name)"
                let item = NSMenuItem(title: title, action: #selector(statusMenuSelectSession(_:)), keyEquivalent: index < 9 ? "\(index + 1)" : "")
                item.keyEquivalentModifierMask = []
                item.tag = index
                item.target = self
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        // Quick actions
        let newClaude = NSMenuItem(title: "New Claude Session", action: #selector(newClaudeSession), keyEquivalent: "")
        newClaude.target = self
        menu.addItem(newClaude)

        let newShell = NSMenuItem(title: "New Shell Session", action: #selector(newShellSession), keyEquivalent: "")
        newShell.target = self
        menu.addItem(newShell)

        menu.addItem(.separator())

        let showWindow = NSMenuItem(title: "Show Window", action: #selector(statusMenuShowWindow), keyEquivalent: "")
        showWindow.target = self
        menu.addItem(showWindow)

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        // Clear the menu after it closes so clicks work again
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.menu = nil
        }
    }

    @objc private func statusMenuSelectSession(_ sender: NSMenuItem) {
        let sessions = SessionManager.shared.listSessions().filter { $0.sessionType != .shell }
        guard sender.tag >= 0, sender.tag < sessions.count else { return }
        let session = sessions[sender.tag]

        if let window = NSApp.keyWindow ?? windows.last {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        activeSplitVC?.selectSession(session.id)
    }

    @objc private func statusMenuShowWindow() {
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

    // MARK: - Icon Helpers

    private func loadAppIcon() -> NSImage? {
        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let img = NSImage(contentsOfFile: path) { return img }
        let devPath = "\(FileManager.default.currentDirectoryPath)/Sources/BlindNinja/Resources/AppIcon.icns"
        return NSImage(contentsOfFile: devPath)
    }

    /// Add transparent padding around the icon so macOS dock badge
    /// sits in the margin instead of bleeding over the artwork.
    static func padIcon(_ icon: NSImage, insetFraction: CGFloat) -> NSImage {
        let canvas = NSSize(width: 1024, height: 1024)
        let inset = canvas.width * insetFraction
        let artRect = NSRect(x: inset, y: inset,
                             width: canvas.width - inset * 2,
                             height: canvas.height - inset * 2)
        let padded = NSImage(size: canvas)
        padded.lockFocus()
        // Transparent background (default)
        icon.draw(in: artRect,
                  from: NSRect(origin: .zero, size: icon.size),
                  operation: .sourceOver, fraction: 1.0)
        padded.unlockFocus()
        return padded
    }

    /// Draw a monochrome template icon for the menu bar — a small ninja head
    /// (circle + horizontal headband line). Template images auto-adapt to
    /// the menu bar's light/dark appearance.
    static func makeMenuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let ctx = NSGraphicsContext.current!.cgContext
            let cx = rect.midX, cy = rect.midY
            let r: CGFloat = 7.0

            // Head circle
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))

            // Headband — horizontal bar across the eyes, clipped to circle
            let bandH: CGFloat = 3.0
            let bandRect = CGRect(x: cx - r + 0.5, y: cy - bandH / 2,
                                  width: r * 2 - 1, height: bandH)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(bandRect)

            // Three dots on headband (traffic light) — black so they show in template mode
            ctx.setFillColor(NSColor.black.cgColor)
            let dotR: CGFloat = 1.2
            for i in 0..<3 {
                let dx = cx - 3.0 + CGFloat(i) * 3.0
                ctx.fillEllipse(in: CGRect(x: dx - dotR, y: cy - dotR,
                                           width: dotR * 2, height: dotR * 2))
            }

            return true
        }
        img.isTemplate = true
        return img
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows.removeAll { $0 === window }
    }
}
