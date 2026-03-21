import AppKit

/// A lightweight code editor view with line numbers, themed styling, and save support.
/// Designed to feel like opening a file in VS Code — not a terminal text editor.
final class FileEditorView: NSView {
    let filePath: String
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let gutterView = LineNumberGutter()
    private var isDirty = false
    private var theme: AppTheme = .blueTitanium

    /// Title shown in the tab — includes a dot when unsaved.
    var tabTitle: String {
        let name = (filePath as NSString).lastPathComponent
        return isDirty ? "\(name) \u{25CF}" : name
    }

    var onDirtyChange: (() -> Void)?

    init(filePath: String, theme: AppTheme) {
        self.filePath = filePath
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        setupViews()
        loadFile()
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setupViews() {
        // Scroll view wrapping the text view
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        // Text view
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesFindPanel = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        let font = NSFont(name: "SF Mono", size: 12)
            ?? NSFont(name: "Menlo", size: 12)
            ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.font = font
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: theme.terminal.foreground
        ]

        // Make the text container span the scroll view width
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView

        // Gutter (line numbers)
        gutterView.textView = textView
        gutterView.font = NSFont(name: "SF Mono", size: 11)
            ?? NSFont(name: "Menlo", size: 11)
            ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        // Layout
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        gutterView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gutterView)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            gutterView.topAnchor.constraint(equalTo: topAnchor),
            gutterView.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutterView.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutterView.widthAnchor.constraint(equalToConstant: 40),

            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: gutterView.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Watch for text changes
        NotificationCenter.default.addObserver(
            self, selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification, object: textView
        )

        // Watch for scroll/layout changes to update gutter
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        scrollView.contentView.postsBoundsChangedNotifications = true
    }

    // MARK: - File I/O

    private func loadFile() {
        guard let data = FileManager.default.contents(atPath: filePath),
              let text = String(data: data, encoding: .utf8) else {
            textView.string = ""
            return
        }
        textView.string = text
        isDirty = false
        gutterView.needsDisplay = true
    }

    func save() -> Bool {
        do {
            try textView.string.write(toFile: filePath, atomically: true, encoding: .utf8)
            isDirty = false
            onDirtyChange?()
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to save"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
            return false
        }
    }

    // MARK: - Theme

    func applyTheme(_ theme: AppTheme) {
        self.theme = theme
        let bg = theme.terminal.background
        let fg = theme.terminal.foreground

        layer?.backgroundColor = bg.cgColor
        textView.backgroundColor = bg
        textView.insertionPointColor = theme.terminal.cursor
        textView.selectedTextAttributes = [
            .backgroundColor: theme.selectedBackground,
            .foregroundColor: fg,
        ]

        // Re-color existing text
        let fullRange = NSRange(location: 0, length: textView.string.utf16.count)
        textView.textStorage?.addAttribute(.foregroundColor, value: fg, range: fullRange)
        textView.typingAttributes = [
            .font: textView.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: fg
        ]

        // Gutter
        gutterView.backgroundColor = bg.blended(withFraction: 0.15, of: .black) ?? bg
        gutterView.textColor = theme.sidebarTextSecondary
        gutterView.needsDisplay = true

        // Scrollbar styling
        scrollView.scrollerStyle = .overlay
    }

    // MARK: - Key handling (Cmd+S)

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "s" {
            _ = save()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Notifications

    @objc private func textDidChange(_ note: Notification) {
        if !isDirty {
            isDirty = true
            onDirtyChange?()
        }
        gutterView.needsDisplay = true
    }

    @objc private func boundsDidChange(_ note: Notification) {
        gutterView.needsDisplay = true
    }

    // MARK: - Focus

    func focus() {
        window?.makeFirstResponder(textView)
    }
}

// MARK: - Line Number Gutter

private final class LineNumberGutter: NSView {
    weak var textView: NSTextView?
    var font: NSFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    var textColor: NSColor = .secondaryLabelColor
    var backgroundColor: NSColor = .controlBackgroundColor

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        dirtyRect.fill()

        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let text = textView.string as NSString
        let visibleRect = textView.enclosingScrollView?.contentView.bounds ?? textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]

        var lineNumber = 1
        // Count lines before visible range
        text.substring(to: charRange.location).enumerateLines { _, _ in
            lineNumber += 1
        }

        let inset = textView.textContainerInset
        var index = charRange.location

        while index < NSMaxRange(charRange) {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyphIdx = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)

            // Adjust for text view's container inset and scroll offset
            lineRect.origin.y += inset.height - visibleRect.origin.y

            let numStr = "\(lineNumber)" as NSString
            let strSize = numStr.size(withAttributes: attrs)
            let drawPoint = NSPoint(
                x: bounds.width - strSize.width - 6,
                y: lineRect.origin.y + (lineRect.height - strSize.height) / 2
            )
            numStr.draw(at: drawPoint, withAttributes: attrs)

            lineNumber += 1
            index = NSMaxRange(lineRange)
        }
    }
}
