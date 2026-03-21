import AppKit

/// NSView with flipped coordinate system (origin at top-left).
/// Required as a container for SwiftTerm's TerminalView which
/// expects top-left origin for correct line rendering order.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
