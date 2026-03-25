import Foundation
import AppKit

extension NSRect {
    func insetBy(_ insets: NSEdgeInsets) -> NSRect {
        let w = max(0, width - insets.left - insets.right)
        let h = max(0, height - insets.top - insets.bottom)
        return NSRect(
            x: origin.x + insets.left,
            y: origin.y + insets.bottom,
            width: w,
            height: h
        )
    }
}

/// Strip ANSI escape sequences from terminal output for state detection.
func stripAnsi(_ s: String) -> String {
    var result = String()
    result.reserveCapacity(s.count)
    var iter = s.makeIterator()

    while let c = iter.next() {
        if c == "\u{1b}" {
            guard let next = iter.next() else { break }
            if next == "[" {
                // CSI sequence (includes DEC private mode like [?2026l)
                // Consume params + intermediate bytes until final byte (0x40-0x7E)
                while let n = iter.next() {
                    let v = n.asciiValue ?? 0
                    if v >= 0x40 && v <= 0x7E { break } // final byte
                }
            } else if next == "]" {
                // OSC sequence — consume until BEL or ST
                while let n = iter.next() {
                    if n == "\u{07}" { break }
                    if n == "\u{1b}" {
                        let _ = iter.next()
                        break
                    }
                }
            } else if next == "(" || next == ")" {
                // Character set designation — consume one more byte
                let _ = iter.next()
            } else {
                // Other ESC sequences (single char like ESC M, ESC 7, etc.)
                // Already consumed the char after ESC
            }
        } else if c == "\r" || c == "\u{0f}" || c == "\u{0e}" {
            // Skip CR, SI, SO control chars
        } else if c.asciiValue.map({ $0 < 32 && $0 != 10 && $0 != 9 }) == true {
            // Skip other control chars except newline and tab
        } else {
            result.append(c)
        }
    }

    return result
}
