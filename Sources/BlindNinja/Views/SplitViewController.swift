import AppKit
import SwiftTerm

/// Root view controller: terminal on the left, sidebar on the right.
final class MainSplitViewController: NSSplitViewController {
    let terminalHost = TerminalHostViewController()
    let sidebar = SidebarViewController()

    private var activeSessionId: String?

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
        sidebar.onNewShellRequested = { [weak self] in
            self?.terminalHost.drawer.createNewShellTab()
        }
        sidebar.onThemeChanged = { theme in
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.currentTheme = theme
                UserDefaults.standard.set(theme.id, forKey: "theme")
            }
        }

        // Listen for session changes
        NotificationCenter.default.addObserver(
            forName: .sessionsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.sidebar.refreshSessions()
        }
    }

    // MARK: - Session Management

    func selectSession(_ sessionId: String) {
        activeSessionId = sessionId
        SessionManager.shared.focusSession(sessionId)
        terminalHost.showSession(sessionId)
        sidebar.setActiveSession(sessionId)
    }

    func selectFirstSession() {
        if let first = SessionManager.shared.listSessions().first {
            selectSession(first.id)
        }
    }

    func selectLastSession() {
        if let last = SessionManager.shared.listSessions().last {
            selectSession(last.id)
        }
    }

    func selectSessionByIndex(_ index: Int) {
        let sessions = SessionManager.shared.listSessions()
        guard index >= 0 && index < sessions.count else { return }
        selectSession(sessions[index].id)
    }

    func selectPreviousSession() {
        let sessions = SessionManager.shared.listSessions().filter { $0.sessionType != .shell }
        guard let current = activeSessionId,
              let idx = sessions.firstIndex(where: { $0.id == current }),
              idx > 0 else { return }
        selectSession(sessions[idx - 1].id)
    }

    func selectNextSession() {
        let sessions = SessionManager.shared.listSessions().filter { $0.sessionType != .shell }
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
        SessionManager.shared.killSession(sessionId)
        if activeSessionId == sessionId {
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
