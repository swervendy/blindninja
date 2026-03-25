import AppKit
import SwiftTerm

/// Root view controller: terminal on the left, sidebar on the right.
final class MainSplitViewController: NSSplitViewController {
    let terminalHost = TerminalHostViewController()
    let sidebar = SidebarViewController()

    private var activeSessionId: String?
    /// Sessions hidden in this window (per-window close without killing the PTY)
    private(set) var hiddenSessionIds: Set<String> = []
    /// Sessions owned by this window — only these appear in the sidebar.
    /// When empty (e.g. legacy/first window), all non-hidden sessions are shown.
    private(set) var ownedSessionIds: Set<String> = []

    override func viewDidLoad() {
        super.viewDidLoad()

        splitView.delegate = self
        splitView.dividerStyle = .thin
        splitView.isVertical = true
        splitView.wantsLayer = true
        splitView.layer?.masksToBounds = true

        // Terminal pane (left) — flexible
        let termItem = NSSplitViewItem(viewController: terminalHost)
        termItem.minimumThickness = 200
        addSplitViewItem(termItem)

        // Sidebar pane (right) — resizable & collapsible
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.minimumThickness = 80
        sidebarItem.maximumThickness = 600
        sidebarItem.canCollapse = true
        addSplitViewItem(sidebarItem)

        // Wire sidebar selection
        sidebar.onSessionSelected = { [weak self] sessionId in
            self?.selectSession(sessionId)
        }
        sidebar.onSessionKill = { [weak self] sessionId in
            self?.killSession(sessionId)
        }
        sidebar.onSessionsKill = { [weak self] sessionIds in
            self?.killSessions(sessionIds)
        }
        sidebar.onNewClaudeRequested = { [weak self] in
            guard let self = self else { return }
            _ = try? self.createOwnedSession(command: "claude")
            self.selectLastSession()
        }
        sidebar.onNewDeployRequested = { [weak self] in
            guard let self = self else { return }
            _ = try? self.createOwnedSession(
                name: "Deploy",
                command: SessionManager.shared.buildDeployCommand()
            )
            self.selectLastSession()
        }
        sidebar.onNewShellRequested = { [weak self] in
            self?.terminalHost.drawer.createNewShellTab()
        }
        sidebar.onThemeChanged = { theme in
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.currentTheme = theme
                UserDefaults.standard.set(theme.id, forKey: "theme")
            }
        }

        // Listen for session changes.
        // Uses throttled refreshSessions() to avoid excessive main-thread work
        // during high-frequency output (e.g. typing). State detection is already
        // throttled to 250ms in the flush timer, so the sidebar doesn't need
        // to rebuild more often than that.
        NotificationCenter.default.addObserver(
            forName: .sessionsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.sidebar.hiddenSessionIds = self.hiddenSessionIds
            self.sidebar.ownedSessionIds = self.ownedSessionIds
            self.sidebar.refreshSessions()
        }
    }

    // MARK: - Session Management

    /// Create a session and register it as owned by this window.
    @discardableResult
    func createOwnedSession(
        name: String? = nil,
        command: String? = nil,
        cwd: String? = nil
    ) throws -> SessionInfo {
        let info = try SessionManager.shared.createSession(name: name, command: command, cwd: cwd)
        ownedSessionIds.insert(info.id)
        return info
    }

    /// Adopt an existing session into this window's owned set.
    func adoptSession(_ sessionId: String) {
        ownedSessionIds.insert(sessionId)
    }

    func selectSession(_ sessionId: String) {
        activeSessionId = sessionId
        SessionManager.shared.focusSession(sessionId)
        terminalHost.showSession(sessionId)
        sidebar.setActiveSession(sessionId)
    }

    /// Sessions visible in this window (scoped to owned sessions, excludes shells and hidden).
    func visibleSessions() -> [SessionInfo] {
        SessionManager.shared.listSessions().filter {
            $0.sessionType != .shell
            && !hiddenSessionIds.contains($0.id)
            && (ownedSessionIds.isEmpty || ownedSessionIds.contains($0.id))
        }
    }

    func selectFirstSession() {
        if let first = visibleSessions().first {
            selectSession(first.id)
        }
    }

    func selectLastSession() {
        if let last = visibleSessions().last {
            selectSession(last.id)
        }
    }

    func selectSessionByIndex(_ index: Int) {
        let sessions = visibleSessions()
        guard index >= 0 && index < sessions.count else { return }
        selectSession(sessions[index].id)
    }

    func selectPreviousSession() {
        let sessions = visibleSessions()
        guard let current = activeSessionId,
              let idx = sessions.firstIndex(where: { $0.id == current }),
              idx > 0 else { return }
        selectSession(sessions[idx - 1].id)
    }

    func selectNextSession() {
        let sessions = visibleSessions()
        guard let current = activeSessionId,
              let idx = sessions.firstIndex(where: { $0.id == current }),
              idx < sessions.count - 1 else { return }
        selectSession(sessions[idx + 1].id)
    }

    func killCurrentSession() {
        guard let id = activeSessionId else { return }
        killSession(id)
    }

    func killSession(_ sessionId: String) {
        killSessions([sessionId])
    }

    func killSessions(_ sessionIds: some Collection<String>) {
        for sessionId in sessionIds {
            hiddenSessionIds.insert(sessionId)

            // Actually kill the PTY only if no other window still shows it
            if let appDelegate = NSApp.delegate as? AppDelegate {
                let stillVisible = appDelegate.windows.contains { window in
                    guard let split = window.contentViewController as? MainSplitViewController,
                          split !== self else { return false }
                    return !split.hiddenSessionIds.contains(sessionId)
                }
                if !stillVisible {
                    SessionManager.shared.killSession(sessionId)
                }
            }
        }

        // Update sidebar once after all kills
        sidebar.hiddenSessionIds = hiddenSessionIds
        sidebar.forceRefreshSessions()

        if let active = activeSessionId, sessionIds.contains(active) {
            activeSessionId = nil
            terminalHost.clearTerminal()
            selectFirstSession()
        }
    }

    func renameCurrentSession() {
        // If the drawer's terminal has focus, rename the active shell tab
        if let firstResponder = view.window?.firstResponder as? NSView,
           firstResponder.isDescendant(of: terminalHost.drawer.view),
           terminalHost.drawer.expanded {
            terminalHost.drawer.startRenameActiveTab()
            return
        }
        guard let id = activeSessionId else { return }
        sidebar.startRename(sessionId: id)
    }

    func toggleSidebar() {
        guard let sidebarItem = splitViewItems.last else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            sidebarItem.animator().isCollapsed = !sidebarItem.isCollapsed
        }
    }

    func toggleDrawer() {
        terminalHost.drawer.toggle()
    }

    func applyTheme(_ theme: AppTheme) {
        terminalHost.applyTheme(theme)
        sidebar.applyTheme(theme)
        // Force divider redraw
        splitView.needsDisplay = true
    }

    // MARK: - NSSplitViewDelegate

    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        // Widen the hit area for easier dragging
        var rect = proposedEffectiveRect
        rect.origin.x -= 4
        rect.size.width += 8
        return rect
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Set initial sidebar width to 240pt
        let sidebarWidth: CGFloat = 240
        splitView.setPosition(splitView.bounds.width - sidebarWidth, ofDividerAt: 0)
    }
}
