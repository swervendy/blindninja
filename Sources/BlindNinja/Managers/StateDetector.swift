import Foundation

/// Port of state_detector.rs — regex-based detection of Claude session state.
final class StateDetector {
    static let shared = StateDetector()

    // Precompiled regex patterns (equivalent to Rust's OnceLock)
    private let claudeActivePatterns: [NSRegularExpression]
    private let claudeBlockedPatterns: [NSRegularExpression]
    private let claudePromptPatterns: [NSRegularExpression]
    private let claudeExitPatterns: [NSRegularExpression]
    private let sessionIdPattern: NSRegularExpression

    private init() {
        // Claude is active if any of these appear in output
        let activeStrings = [
            "╭─", "╰─", "╭━", "╰━",
            "Claude Code",
            "session:\\s*[0-9a-f-]{36}",
            "\\(thinking\\)",
            "\\(tool\\)",
            "\\(read\\)",
            "\\(write\\)",
            "\\(edit\\)",
            "\\(search\\)",
            "\\? for shortcuts",
        ]

        // Claude is blocked / waiting for approval
        let blockedStrings = [
            "\\(y/n\\)", "\\(Y/n\\)", "\\(y/N\\)", "\\[y/N\\]", "\\[Y/n\\]",
            "Would you like",
            "Shall I",
            "Do you want",
            "confirm",
            "Proceed\\?",
            "Continue\\?",
            "Allow\\?",
            "approve",
            "permission",
            "Accept\\?",
            "\\(yes/no\\)",
            "Press Enter",
            "Press any key",
            "waiting for",
            "requires approval",
            "needs your",
            "review and",
            "before proceeding",
            "to continue",
            "Do you want to overwrite",
        ]

        // Claude is at a prompt (waiting for user input)
        let promptStrings = [
            "❯\\s*$",
            "\u{203A}\\s*$",   // › (single right-pointing angle quotation mark)
            "\\? for shortcuts",
        ]

        // Claude has exited back to shell
        let exitStrings = [
            "%\\s*$",     // zsh prompt
            "\\$\\s*$",   // bash prompt
            "\\(base\\).*%\\s*$", // conda prompt
        ]

        func compile(_ patterns: [String], options: NSRegularExpression.Options = []) -> [NSRegularExpression] {
            patterns.compactMap { try? NSRegularExpression(pattern: $0, options: options) }
        }

        claudeActivePatterns = compile(activeStrings)
        claudeBlockedPatterns = compile(blockedStrings)
        // Use anchorsMatchLines so $ matches end of each line, not just end of string
        claudePromptPatterns = compile(promptStrings, options: .anchorsMatchLines)
        claudeExitPatterns = compile(exitStrings, options: .anchorsMatchLines)
        sessionIdPattern = try! NSRegularExpression(
            pattern: "(?:resume|session|conversation)[:\\s_-]*([0-9a-f-]{36})",
            options: .caseInsensitive
        )
    }

    /// Detect whether Claude appears to be running in this terminal.
    func detectClaudeActive(in stripped: String, wasActive: Bool) -> Bool {
        let range = NSRange(stripped.startIndex..., in: stripped)

        // Check for exit patterns first — if we see a shell prompt, Claude has exited
        if wasActive {
            // Only check last few lines for exit
            let lastLines = lastNLines(stripped, n: 3)
            let lastRange = NSRange(lastLines.startIndex..., in: lastLines)
            for pattern in claudeExitPatterns {
                if pattern.firstMatch(in: lastLines, range: lastRange) != nil {
                    return false
                }
            }
        }

        // Check for active patterns anywhere in the buffer
        for pattern in claudeActivePatterns {
            if pattern.firstMatch(in: stripped, range: range) != nil {
                return true
            }
        }

        return wasActive // maintain previous state if no signals
    }

    /// Detect session state from stripped terminal output.
    func detectState(
        stripped: String,
        msSinceOutput: UInt64,
        idleThresholdMs: UInt64 = 8000,
        claudeActive: Bool
    ) -> SessionState {
        if stripped.isEmpty {
            return .new
        }

        guard claudeActive else {
            return .idle // non-Claude shell is always idle
        }

        let lastLines = lastNLines(stripped, n: 15)
        let lastRange = NSRange(lastLines.startIndex..., in: lastLines)

        // Check blocked patterns (approval prompts)
        for pattern in claudeBlockedPatterns {
            if pattern.firstMatch(in: lastLines, range: lastRange) != nil {
                return .blocked
            }
        }

        // Check prompt patterns (waiting for user input)
        for pattern in claudePromptPatterns {
            if pattern.firstMatch(in: lastLines, range: lastRange) != nil {
                return .waiting
            }
        }

        // Time-based: working if recent output, idle if stale
        if msSinceOutput < idleThresholdMs {
            return .working
        }

        return .idle
    }

    /// Parse a Claude session ID (UUID) from terminal output.
    func parseClaudeSessionId(from stripped: String) -> String? {
        let range = NSRange(stripped.startIndex..., in: stripped)
        guard let match = sessionIdPattern.firstMatch(in: stripped, range: range) else {
            return nil
        }
        guard let idRange = Range(match.range(at: 1), in: stripped) else {
            return nil
        }
        return String(stripped[idRange])
    }

    // MARK: - Helpers

    private func lastNLines(_ s: String, n: Int) -> String {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        let start = max(0, lines.count - n)
        return lines[start...].joined(separator: "\n")
    }
}
