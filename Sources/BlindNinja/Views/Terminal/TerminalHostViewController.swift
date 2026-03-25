import AppKit
import SwiftTerm

/// Hosts the terminal view for the active session + bottom drawer for shell sessions.
/// Manages a pool of TerminalView instances (one per session) for instant switching.
final class TerminalHostViewController: NSViewController, TerminalViewDelegate {
    private let mainTerminalContainer = NSView()
    let drawer = DrawerViewController()
    private var activeSessionId: String?
    private var activeTerminalView: TerminalView?
    private var fontSize: CGFloat = 13
    private let minFontSize: CGFloat = 8
    private let maxFontSize: CGFloat = 28
    private var currentTheme: AppTheme = .blueTitanium
    /// Track last sent PTY dimensions to avoid redundant resize calls during layout storms
    private var lastResizeCols: Int = 0
    private var lastResizeRows: Int = 0
    /// Debounce timer for PTY resize — prevents resize storms during window drag
    private var resizeDebounce: DispatchWorkItem?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = currentTheme.terminal.background.cgColor
        root.layer?.masksToBounds = true
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Main terminal container (fills available space above drawer)
        mainTerminalContainer.wantsLayer = true
        mainTerminalContainer.layer?.masksToBounds = true
        mainTerminalContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mainTerminalContainer)

        // Drawer at bottom
        addChild(drawer)
        drawer.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(drawer.view)

        NSLayoutConstraint.activate([
            mainTerminalContainer.topAnchor.constraint(equalTo: view.topAnchor),
            mainTerminalContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mainTerminalContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mainTerminalContainer.bottomAnchor.constraint(equalTo: drawer.view.topAnchor),

            drawer.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            drawer.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            drawer.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Register for file drops on the main terminal container
        registerForDraggedTypes([.fileURL])
    }

    private let termInset = NSEdgeInsets(top: 8, left: 8, bottom: 4, right: 4)

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let termView = activeTerminalView, let sessionId = activeSessionId else { return }
        let newFrame = mainTerminalContainer.bounds.insetBy(termInset)
        guard newFrame.width > 0 && newFrame.height > 0 else { return }
        termView.frame = newFrame

        // Debounce PTY resize to prevent resize storms during window drag.
        // SwiftTerm updates its internal grid immediately when the frame changes,
        // but we delay sending TIOCSWINSZ to the PTY so TUI apps only re-render
        // once the resize settles — preventing jumbled output.
        let terminal = termView.getTerminal()
        let cols = terminal.cols
        let rows = terminal.rows
        guard cols != lastResizeCols || rows != lastResizeRows else { return }

        resizeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.activeSessionId == sessionId else { return }
            let t = termView.getTerminal()
            let c = t.cols, r = t.rows
            guard c != self.lastResizeCols || r != self.lastResizeRows else { return }
            self.lastResizeCols = c
            self.lastResizeRows = r
            SessionManager.shared.resizeSession(sessionId, cols: UInt16(c), rows: UInt16(r))
        }
        resizeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Show the terminal for a given session.
    func showSession(_ sessionId: String) {
        activeTerminalView?.removeFromSuperview()
        activeSessionId = sessionId
        // Reset resize cache so we always send correct dimensions for the new session
        lastResizeCols = 0
        lastResizeRows = 0

        let termView: TerminalView
        if let existing = SessionManager.shared.terminalViews[sessionId] {
            termView = existing
        } else {
            termView = createTerminalView(for: sessionId)
            SessionManager.shared.registerTerminalView(termView, for: sessionId)
        }

        let frame = mainTerminalContainer.bounds.insetBy(termInset)
        if frame.width > 0 && frame.height > 0 {
            termView.frame = frame
        }
        termView.autoresizingMask = [.width, .height]
        mainTerminalContainer.addSubview(termView)
        activeTerminalView = termView

        // Send immediate resize for the new session — don't debounce the initial size sync
        let terminal = termView.getTerminal()
        let cols = terminal.cols, rows = terminal.rows
        if cols > 0 && rows > 0 {
            lastResizeCols = cols
            lastResizeRows = rows
            SessionManager.shared.resizeSession(sessionId, cols: UInt16(cols), rows: UInt16(rows))
        }

        // Remove focus from drawer terminal so its cursor hides
        drawer.resignActiveTerminalFocus()

        // Hide native caret for Claude/deploy sessions (they render their own cursor).
        // Use lightweight accessor instead of full listSessions().
        let sessionType = SessionManager.shared.getSessionType(sessionId)
        if sessionType != .shell {
            DispatchQueue.main.async { Self.hideCaretView(in: termView) }
        }

        view.window?.makeFirstResponder(termView)
    }

    func clearTerminal() {
        activeTerminalView?.removeFromSuperview()
        activeTerminalView = nil
        activeSessionId = nil
    }

    func adjustFontSize(delta: CGFloat) {
        fontSize = max(minFontSize, min(maxFontSize, fontSize + delta))
        applyFontSize()
    }

    func resetFontSize() {
        fontSize = 13
        applyFontSize()
    }

    func applyTheme(_ theme: AppTheme) {
        currentTheme = theme
        view.layer?.backgroundColor = theme.terminal.background.cgColor

        for (_, termView) in SessionManager.shared.terminalViews {
            applyTerminalTheme(termView, theme: theme)
        }

        drawer.applyTheme(theme)
    }

    // MARK: - Drag and Drop (file drop into terminal)

    private func registerForDraggedTypes(_ types: [NSPasteboard.PasteboardType]) {
        mainTerminalContainer.registerForDraggedTypes(types)

        // We need to use a subclass or override on the container to accept drops.
        // Instead, set up an invisible drop target overlay.
        let dropTarget = TerminalDropTarget()
        dropTarget.onDrop = { [weak self] paths in
            self?.handleFileDrop(paths)
        }
        dropTarget.frame = mainTerminalContainer.bounds
        dropTarget.autoresizingMask = [.width, .height]
        mainTerminalContainer.addSubview(dropTarget, positioned: .below, relativeTo: nil)
    }

    private func handleFileDrop(_ paths: [String]) {
        guard let sessionId = activeSessionId else { return }
        // Shell-escape paths and paste them into the terminal
        let escaped = paths.map { shellEscape($0) }.joined(separator: " ")
        SessionManager.shared.writeToSession(sessionId, string: escaped)
    }

    private func shellEscape(_ path: String) -> String {
        // Wrap in single quotes, escaping existing single quotes
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    // MARK: - Private

    private func createTerminalView(for sessionId: String) -> TerminalView {
        let termView = TerminalView(frame: mainTerminalContainer.bounds)
        termView.wantsLayer = true
        termView.layer?.masksToBounds = true
        termView.terminalDelegate = self

        let font = NSFont(name: "SF Mono", size: fontSize)
            ?? NSFont(name: "Menlo", size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        termView.font = font

        applyTerminalTheme(termView, theme: currentTheme)
        termView.optionAsMetaKey = true

        // Hide SwiftTerm's built-in NSScroller (it uses .legacy style = fat white bar)
        DispatchQueue.main.async {
            Self.hideScroller(in: termView)
        }

        return termView
    }

    private func applyTerminalTheme(_ termView: TerminalView, theme: AppTheme) {
        let tc = theme.terminal
        let palette = tc.ansi.map { mkColor($0) }
        if palette.count == 16 {
            termView.installColors(palette)
        }
        termView.nativeBackgroundColor = tc.background
        termView.nativeForegroundColor = tc.foreground
    }

    private func mkColor(_ nsColor: NSColor) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let c = nsColor.usingColorSpace(.sRGB) ?? nsColor
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return Color(red: UInt16(r * 65535), green: UInt16(g * 65535), blue: UInt16(b * 65535))
    }

    private func applyFontSize() {
        let font = NSFont(name: "SF Mono", size: fontSize)
            ?? NSFont(name: "Menlo", size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        for (_, termView) in SessionManager.shared.terminalViews {
            termView.font = font
        }
    }

    // MARK: - Helpers

    /// Configure SwiftTerm's internal NSScrollView to hide scrollers without breaking scroll behavior
    static func hideScroller(in view: NSView) {
        for subview in view.subviews {
            if let scrollView = subview as? NSScrollView {
                scrollView.scrollerStyle = .overlay
                scrollView.hasVerticalScroller = false
                scrollView.hasHorizontalScroller = false
                return
            }
            hideScroller(in: subview)
        }
    }

    /// Hide SwiftTerm's CaretView (native cursor) — used for Claude/deploy sessions that render their own cursor.
    /// Recurses into subviews in case CaretView is nested inside a scroll view or other container.
    static func hideCaretView(in view: NSView) {
        for subview in view.subviews {
            if String(describing: type(of: subview)) == "CaretView" {
                subview.isHidden = true
                return
            }
            hideCaretView(in: subview)
        }
    }

    // MARK: - TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let sessionId = activeSessionId else { return }
        guard newCols != lastResizeCols || newRows != lastResizeRows else { return }
        // Debounce — viewDidLayout already handles the delayed PTY resize
        resizeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.activeSessionId == sessionId else { return }
            let t = source.getTerminal()
            let c = t.cols, r = t.rows
            guard c != self.lastResizeCols || r != self.lastResizeRows else { return }
            self.lastResizeCols = c
            self.lastResizeRows = r
            SessionManager.shared.resizeSession(sessionId, cols: UInt16(c), rows: UInt16(r))
        }
        resizeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        guard let sessionId = activeSessionId else { return }
        SessionManager.shared.parseTerminalTitle(sessionId, title: title)
    }

    /// Kitty keyboard protocol keypad codes → standard CSI sequences.
    /// macOS reports arrow keys with .numericPad modifier, so SwiftTerm maps them to
    /// keypad variants (e.g. keypadDown=57420) instead of regular arrows. Claude Code's
    /// TUI components (e.g. /resume search) don't handle these, showing raw codes.
    static let kittyCsiReplacements: [String: [UInt8]] = {
        let esc: UInt8 = 0x1b
        return [
            // Keypad arrow keys (macOS arrow keys have .numericPad flag)
            "\u{1b}[57419u": [esc, 0x5b, 0x41],  // keypadUp    → ESC[A
            "\u{1b}[57420u": [esc, 0x5b, 0x42],  // keypadDown  → ESC[B
            "\u{1b}[57422u": [esc, 0x5b, 0x43],  // keypadRight → ESC[C
            "\u{1b}[57421u": [esc, 0x5b, 0x44],  // keypadLeft  → ESC[D
            // Keypad nav keys
            "\u{1b}[57423u": [esc, 0x5b, 0x48],  // keypadHome  → ESC[H
            "\u{1b}[57424u": [esc, 0x5b, 0x46],  // keypadEnd   → ESC[F
            "\u{1b}[57425u": [esc, 0x5b, 0x35, 0x7e], // keypadPgUp   → ESC[5~
            "\u{1b}[57426u": [esc, 0x5b, 0x36, 0x7e], // keypadPgDown → ESC[6~
            "\u{1b}[57428u": [esc, 0x5b, 0x32, 0x7e], // keypadInsert → ESC[2~
            "\u{1b}[57429u": [esc, 0x5b, 0x33, 0x7e], // keypadDelete → ESC[3~
        ]
    }()

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let sessionId = activeSessionId else { return }

        // Check for kitty-encoded navigation keys and translate to standard CSI
        if data.count >= 5 && data.count <= 10 && data.first == 0x1b {
            if let str = String(bytes: data, encoding: .utf8),
               let replacement = Self.kittyCsiReplacements[str] {
                SessionManager.shared.writeToSession(sessionId, data: Data(replacement))
                return
            }
        }

        SessionManager.shared.writeToSession(sessionId, data: Data(data))
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
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Drop Target for files

final class TerminalDropTarget: NSView {
    var onDrop: (([String]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self]) else {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return false
        }
        let paths = urls.map { $0.path }
        onDrop?(paths)
        return true
    }
}
