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
        termView.frame = newFrame
        let terminal = termView.getTerminal()
        SessionManager.shared.resizeSession(sessionId, cols: UInt16(terminal.cols), rows: UInt16(terminal.rows))
    }

    /// Show the terminal for a given session.
    func showSession(_ sessionId: String) {
        activeTerminalView?.removeFromSuperview()
        activeSessionId = sessionId

        let termView: TerminalView
        if let existing = SessionManager.shared.terminalViews[sessionId] {
            termView = existing
        } else {
            termView = createTerminalView(for: sessionId)
            SessionManager.shared.registerTerminalView(termView, for: sessionId)
        }

        termView.frame = mainTerminalContainer.bounds.insetBy(termInset)
        termView.autoresizingMask = [.width, .height]
        mainTerminalContainer.addSubview(termView)
        activeTerminalView = termView

        // Remove focus from drawer terminal so its cursor hides
        drawer.resignActiveTerminalFocus()

        // Hide native caret for Claude/deploy sessions (they render their own cursor)
        let session = SessionManager.shared.listSessions().first { $0.id == sessionId }
        if session?.sessionType != .shell {
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

    /// Recursively find and hide any NSScroller in the view hierarchy
    static func hideScroller(in view: NSView) {
        for subview in view.subviews {
            if let scroller = subview as? NSScroller {
                scroller.isHidden = true
                scroller.alphaValue = 0
            }
            hideScroller(in: subview)
        }
    }

    /// Hide SwiftTerm's CaretView (native cursor) — used for Claude/deploy sessions that render their own cursor
    static func hideCaretView(in view: NSView) {
        for subview in view.subviews {
            if String(describing: type(of: subview)) == "CaretView" {
                subview.isHidden = true
                return
            }
        }
    }

    // MARK: - TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let sessionId = activeSessionId else { return }
        SessionManager.shared.resizeSession(sessionId, cols: UInt16(newCols), rows: UInt16(newRows))
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        guard let sessionId = activeSessionId else { return }
        SessionManager.shared.parseTerminalTitle(sessionId, title: title)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let sessionId = activeSessionId else { return }
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
