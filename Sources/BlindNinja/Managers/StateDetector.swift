import Foundation

/// Port of state_detector.rs — regex-based detection of Claude session state.
final class StateDetector {
    static let shared = StateDetector()

    // Precompiled regex patterns (equivalent to Rust's OnceLock)
    private let claudeActivePatterns: [NSRegularExpression]
    private let claudeBlockedPatterns: [NSRegularExpression]
    private let claudePromptPatterns: [NSRegularExpression]
    /// Patterns that indicate Claude is actively processing (thinking, using tools, etc.)
    /// Distinguished from prompt patterns — these mean "Claude is doing work right now".
    private let claudeWorkingIndicators: [NSRegularExpression]
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

        // Claude is at a prompt (waiting for user input).
        // Includes broad patterns that match even when the user has typed text after the prompt char.
        let promptStrings = [
            "❯\\s*$",              // empty ❯ prompt
            "\u{203A}\\s*$",       // empty › prompt
            "^\\s*❯",              // ❯ at start of line (matches with typed text too)
            "^\\s*\u{203A}",       // › at start of line
            "\\? for shortcuts",
        ]

        // Indicators that Claude is actively working (thinking, tool use, etc.).
        // When these are visible on screen, "working" takes priority over prompt detection.
        let workingIndicatorStrings = [
            "\\(thinking\\)",
            "\\(tool\\)",
            "\\(read\\)",
            "\\(write\\)",
            "\\(edit\\)",
            "\\(search\\)",
            "\\(bash\\)",
            "Streaming\\.\\.\\.",
            // Claude Code reliable indicators
            "esc to interrupt",          // always shown when Claude is processing
            "\\d+\\.?\\d*k? tokens",     // token count in status line (e.g. "4.4k tokens", "350 tokens")
            "Queried \\w+",              // MCP query indicator
            "\\w+\u{2026}\\s+\\(\\d+",   // Verb… (time — e.g. "Proofing… (2m"
            "Running\u{2026}",           // Running…
            "Running\\.\\.\\.",          // Running...
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
        // Use anchorsMatchLines so $ and ^ match each line, not just start/end of string
        claudePromptPatterns = compile(promptStrings, options: .anchorsMatchLines)
        claudeWorkingIndicators = compile(workingIndicatorStrings)
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

        // Use last 40 lines for broad checks
        let lastLines = lastNLines(stripped, n: 40)
        let lastRange = NSRange(lastLines.startIndex..., in: lastLines)

        // 1. Check blocked patterns (approval prompts) — highest priority
        for pattern in claudeBlockedPatterns {
            if pattern.firstMatch(in: lastLines, range: lastRange) != nil {
                return .blocked
            }
        }

        // 2. Check for active working indicators (thinking, tool use, etc.) in the
        //    bottom portion of the screen. These explicitly mean Claude is processing.
        let recentLines = lastNLines(stripped, n: 12)
        let recentRange = NSRange(recentLines.startIndex..., in: recentLines)
        let hasWorkingIndicators = claudeWorkingIndicators.contains { pattern in
            pattern.firstMatch(in: recentLines, range: recentRange) != nil
        }

        if hasWorkingIndicators {
            return .working
        }

        // 3. Check prompt patterns (waiting for user input).
        //    This comes BEFORE the time-based "working" check because typing at the
        //    prompt generates keystroke echo output — we don't want that to show as "working".
        let promptLines = lastNLines(stripped, n: 5)
        let promptRange = NSRange(promptLines.startIndex..., in: promptLines)
        for pattern in claudePromptPatterns {
            if pattern.firstMatch(in: promptLines, range: promptRange) != nil {
                return .waiting
            }
        }

        // 4. Time-based: working if recent output, idle if stale
        if msSinceOutput < 2000 {
            return .working
        }
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
