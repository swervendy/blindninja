import AppKit
import Foundation
import SwiftTerm

/// Notification names for UI updates
extension Notification.Name {
    static let sessionsChanged = Notification.Name("sessionsChanged")
    static let sessionOutput = Notification.Name("sessionOutput")
}

/// Manages all terminal sessions — PTY lifecycle, output buffering, state detection.
final class SessionManager {
    static let shared = SessionManager()

    /// Build the deploy agent command with dynamic context about active sessions and project root
    func buildDeployCommand() -> String {
        let activeSessions = listSessions()
        lock.lock()
        let root = projectRoot
        lock.unlock()

        let worktreeLines = activeSessions
            .filter { $0.sessionType == .claude && $0.worktreePath != nil && $0.branchName != nil }
            .map { session -> String in
                let name = session.customName ?? session.aiName ?? session.name
                let branch = session.branchName ?? "main"
                let path = session.worktreePath ?? root
                return "\(name): branch=\(branch) path=\(path)"
            }

        var prompt = "You are a deployment agent. Project root: \(root)."

        if !worktreeLines.isEmpty {
            prompt += " Active Claude sessions with worktrees: " + worktreeLines.joined(separator: "; ") + "."
        }

        prompt += " Follow this workflow:"
        prompt += " 1) WORKTREES: Check for uncommitted changes."
        if !worktreeLines.isEmpty {
            prompt += " Start with the active session worktrees listed above — those have in-progress work from other Claude sessions."
        }
        prompt += " Also check the main repo at the project root."
        prompt += " For each location with changes, review the diffs to understand what was changed, then commit and merge into the main branch."
        prompt += " 2) BUILD: Run the project build command (e.g. npm run build). If it fails, fix the issues and rebuild until it passes."
        prompt += " 3) PUSH: git add, commit, and push changes to the remote."
        prompt += " 4) CI: Check GitHub Actions status with 'gh run list --limit 5' and 'gh run view <id>'. If any checks fail, read the logs with 'gh run view <id> --log-failed', fix the issues, push again, and re-check. Iterate until CI passes."
        prompt += " 5) DEPLOY: Verify deploy status using any available Render MCP tools. If the deploy fails, check the logs, fix issues, and redeploy. Iterate until the deploy succeeds."
        prompt += " 6) SUMMARY: When everything is green, print a deployment summary with: the branch/commit deployed, a bullet list of features and changes included (derived from commit messages and diffs), CI status, and deploy status. Keep it concise."
        prompt += " Be concise throughout. Focus on getting the deploy done end-to-end."

        // Escape for shell double-quote context
        let escaped = prompt
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")

        return "claude" +
            " --allowedTools" +
            " 'Bash(*)'" +
            " Read Grep Glob Edit Write WebFetch WebSearch 'mcp__*'" +
            " --system-prompt \"\(escaped)\""
    }

    private let maxOutputBuffer = 50 * 1024 // 50KB

    private var sessions: [String: SessionInner] = [:]
    private let lock = NSLock()
    private(set) var projectRoot: String

    /// Terminal views keyed by session ID — one per session for instant switching
    private(set) var terminalViews: [String: TerminalView] = [:]

    private init() {
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Projects")
        if FileManager.default.fileExists(atPath: defaultPath.path) {
            projectRoot = defaultPath.path
        } else {
            projectRoot = FileManager.default.currentDirectoryPath
        }
    }

    // MARK: - Internal session state

    private class SessionInner {
        var info: SessionInfo
        var outputBuffer: String = ""
        var strippedTail: String = ""
        /// Screen content from SwiftTerm buffer — more accurate than raw output for TUI apps
        var cachedScreenText: String = ""
        var pty: PTYHandle?
        var lastOutputTime: UInt64
        var claudeActive: Bool

        init(info: SessionInfo, pty: PTYHandle?, claudeActive: Bool) {
            self.info = info
            self.pty = pty
            self.lastOutputTime = info.createdAt
            self.claudeActive = claudeActive
        }
    }

    // MARK: - Public API

    func setProjectRoot(_ path: String) {
        lock.lock()
        projectRoot = path
        lock.unlock()
    }

    func listSessions() -> [SessionInfo] {
        // State detection now happens in the flush timer (after terminal feed)
        // and the idle state timer — this method just returns cached state.
        lock.lock()
        var list = sessions.values
            .filter { !$0.info.archived }
            .map { $0.info }
        lock.unlock()

        // Sort: starred first, then by sort order, then by creation time
        list.sort { a, b in
            if a.starred != b.starred { return a.starred && !b.starred }
            switch (a.sortOrder, b.sortOrder) {
            case (0, 0): return a.createdAt < b.createdAt
            case (0, _): return false
            case (_, 0): return true
            default: return a.sortOrder < b.sortOrder
            }
        }

        return list
    }

    // MARK: - Lightweight Accessors (avoid triggering state detection)

    /// Get session type without full listSessions() overhead.
    func getSessionType(_ sessionId: String) -> SessionType? {
        lock.lock()
        let type = sessions[sessionId]?.info.sessionType
        lock.unlock()
        return type
    }

    /// Get display name without full listSessions() overhead.
    func getSessionName(_ sessionId: String) -> String? {
        lock.lock()
        let info = sessions[sessionId]?.info
        lock.unlock()
        guard let info = info else { return nil }
        return info.customName ?? info.aiName ?? info.name
    }

    @discardableResult
    func createSession(
        name: String? = nil,
        command: String? = nil,
        cwd: String? = nil,
        cols: UInt16 = 120,
        rows: UInt16 = 30
    ) throws -> SessionInfo {
        let sessionId = UUID().uuidString.lowercased()
        let now = nowMs()
        let baseCwd = cwd ?? projectRoot

        let isClaudeCmd = command?.hasPrefix("claude") ?? false
        let isDeploy = name == "Deploy"
        let sessionType: SessionType = isDeploy ? .deploy : (isClaudeCmd ? .claude : .shell)
        let useWorktree = UserDefaults.standard.bool(forKey: "enableWorktree") && isClaudeCmd && !isDeploy

        var effectiveCwd = baseCwd
        var wtPath: String? = nil
        var wtBranch: String? = nil

        if useWorktree {
            do {
                let result = try WorktreeManager.createWorktree(repoPath: baseCwd)
                effectiveCwd = result.path
                wtPath = result.path
                wtBranch = result.branch
            } catch {
                // Fall back to normal cwd if worktree creation fails
                print("Worktree creation failed: \(error). Using normal cwd.")
            }
        }

        let pty = try PTYHandle.spawn(
            command: command,
            cwd: effectiveCwd,
            cols: cols,
            rows: rows
        )

        let displayName = name ?? (isClaudeCmd ? "Session \(sessionId.prefix(8))" : "Shell")

        let info = SessionInfo(
            id: sessionId,
            name: displayName,
            aiName: nil,
            customName: nil,
            state: .new,
            lastActivity: now,
            lastLine: "",
            claudeSessionId: nil,
            claudeResumeCmd: nil,
            hasUnread: false,
            stateChangedAt: now,
            worktreePath: wtPath ?? effectiveCwd,
            branchName: wtBranch,
            pid: pty.pid,
            claudeActive: isClaudeCmd,
            createdAt: now,
            starred: false,
            archived: false,
            sortOrder: 0,
            sessionType: sessionType
        )

        let inner = SessionInner(info: info, pty: pty, claudeActive: isClaudeCmd)

        lock.lock()
        sessions[sessionId] = inner
        lock.unlock()

        // Start the PTY reader on a background thread
        let reader = pty.makeReader()
        startReaderThread(sessionId: sessionId, reader: reader)

        notifySessionsChanged()
        return info
    }

    func killSession(_ sessionId: String) {
        lock.lock()
        let session = sessions.removeValue(forKey: sessionId)
        lock.unlock()

        // Clean up worktree if one was created for this session
        if let info = session?.info, let wtPath = info.worktreePath, info.branchName != nil {
            DispatchQueue.global(qos: .utility).async { [projectRoot] in
                WorktreeManager.removeWorktree(repoPath: projectRoot, worktreePath: wtPath)
            }
        }

        session?.pty?.kill()

        DispatchQueue.main.async {
            self.terminalViews.removeValue(forKey: sessionId)
        }

        notifySessionsChanged()
    }

    /// Extract Claude conversation ID from terminal title set by Claude Code.
    /// Claude Code sets the title to formats like "Claude Code - <uuid>" or just contains a UUID.
    private static let uuidPattern = try! NSRegularExpression(
        pattern: "([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})",
        options: .caseInsensitive
    )

    /// Match OSC title sequences: ESC ] 0; title BEL  or  ESC ] 2; title BEL/ST
    private static let oscTitlePattern = try! NSRegularExpression(
        pattern: "\\x1b\\][02];([^\\x07\\x1b]*?)(?:\\x07|\\x1b\\\\)",
        options: []
    )

    /// Parse OSC title escape sequences from raw terminal output to extract Claude session UUID.
    /// This works for all sessions, not just the one currently displayed.
    private func parseOSCTitle(from raw: String, sessionId: String) {
        let range = NSRange(raw.startIndex..., in: raw)
        let matches = Self.oscTitlePattern.matches(in: raw, range: range)
        for match in matches {
            guard let titleRange = Range(match.range(at: 1), in: raw) else { continue }
            let title = String(raw[titleRange])
            // Try to extract a UUID from the title
            let titleNSRange = NSRange(title.startIndex..., in: title)
            if let uuidMatch = Self.uuidPattern.firstMatch(in: title, range: titleNSRange),
               let idRange = Range(uuidMatch.range(at: 1), in: title) {
                let claudeId = String(title[idRange])
                lock.lock()
                if let session = sessions[sessionId], session.info.claudeSessionId == nil {
                    session.info.claudeSessionId = claudeId
                    session.info.claudeResumeCmd = "claude --resume \(claudeId)"
                }
                lock.unlock()
                return
            }
        }
    }

    func parseTerminalTitle(_ sessionId: String, title: String) {
        lock.lock()
        guard let session = sessions[sessionId],
              session.info.claudeSessionId == nil,
              session.info.sessionType == .claude || session.info.sessionType == .deploy else {
            lock.unlock()
            return
        }
        let range = NSRange(title.startIndex..., in: title)
        if let match = Self.uuidPattern.firstMatch(in: title, range: range),
           let idRange = Range(match.range(at: 1), in: title) {
            let claudeId = String(title[idRange])
            session.info.claudeSessionId = claudeId
            session.info.claudeResumeCmd = "claude --resume \(claudeId)"
        }
        lock.unlock()
    }

    func focusSession(_ sessionId: String) {
        lock.lock()
        sessions[sessionId]?.info.hasUnread = false
        lock.unlock()
    }

    func writeToSession(_ sessionId: String, data: Data) {
        lock.lock()
        let pty = sessions[sessionId]?.pty
        lock.unlock()
        pty?.write(data)
    }

    func writeToSession(_ sessionId: String, string: String) {
        lock.lock()
        let pty = sessions[sessionId]?.pty
        lock.unlock()
        pty?.write(string)
    }

    func resizeSession(_ sessionId: String, cols: UInt16, rows: UInt16) {
        lock.lock()
        let pty = sessions[sessionId]?.pty
        lock.unlock()
        pty?.resize(cols: cols, rows: rows)
    }

    func renameSession(_ sessionId: String, name: String) {
        lock.lock()
        if let s = sessions[sessionId] {
            s.info.customName = name
            s.info.name = name
        }
        lock.unlock()
        notifySessionsChanged()
    }

    func setAiName(_ sessionId: String, name: String) {
        lock.lock()
        if let s = sessions[sessionId] {
            s.info.aiName = name
            if s.info.customName == nil {
                s.info.name = name
            }
        }
        lock.unlock()
        notifySessionsChanged()
    }

    func getOutputBuffer(_ sessionId: String) -> String? {
        lock.lock()
        let buf = sessions[sessionId]?.outputBuffer
        lock.unlock()
        return buf
    }

    func toggleStar(_ sessionId: String) -> Bool {
        lock.lock()
        let starred = sessions[sessionId].map { s in
            s.info.starred.toggle()
            return s.info.starred
        } ?? false
        lock.unlock()
        notifySessionsChanged()
        return starred
    }

    func archiveSession(_ sessionId: String) {
        lock.lock()
        if let s = sessions[sessionId] {
            s.info.archived = true
            s.pty?.kill()
            s.pty = nil
        }
        lock.unlock()
        notifySessionsChanged()
    }

    func reorderSessions(_ sessionIds: [String]) {
        lock.lock()
        for (i, id) in sessionIds.enumerated() {
            sessions[id]?.info.sortOrder = UInt32(i + 1)
        }
        lock.unlock()
    }

    func getResumeCommand(_ sessionId: String) -> String? {
        lock.lock()
        let cmd = sessions[sessionId]?.info.claudeResumeCmd
        lock.unlock()
        return cmd
    }

    /// Register a TerminalView for a session (called from UI layer)
    func registerTerminalView(_ view: TerminalView, for sessionId: String) {
        terminalViews[sessionId] = view
    }

    // MARK: - Persistence

    func saveAllSessions() {
        lock.lock()
        let snapshot = sessions.values.map { (info: $0.info, outputBuffer: $0.outputBuffer) }
        let root = projectRoot
        lock.unlock()

        SessionPersistence.shared.saveAll(projectRoot: root, sessions: snapshot)
    }

    func restoreSessions(cols: UInt16 = 120, rows: UInt16 = 30) {
        let (savedRoot, savedSessions) = SessionPersistence.shared.loadAll()
        guard !savedSessions.isEmpty else { return }

        if let root = savedRoot {
            setProjectRoot(root)
        }

        for saved in savedSessions {
            // Try to recover Claude session UUID from saved output buffer if not already set
            var info = saved.info
            if info.claudeSessionId == nil && (info.sessionType == SessionType.claude || info.sessionType == SessionType.deploy) {
                let bufferRange = NSRange(saved.outputBuffer.startIndex..., in: saved.outputBuffer)
                let oscMatches = Self.oscTitlePattern.matches(in: saved.outputBuffer, range: bufferRange)
                for oscMatch in oscMatches {
                    guard let titleRange = Range(oscMatch.range(at: 1), in: saved.outputBuffer) else { continue }
                    let title = String(saved.outputBuffer[titleRange])
                    let titleNSRange = NSRange(title.startIndex..., in: title)
                    if let uuidMatch = Self.uuidPattern.firstMatch(in: title, range: titleNSRange),
                       let idRange = Range(uuidMatch.range(at: 1), in: title) {
                        let claudeId = String(title[idRange])
                        info.claudeSessionId = claudeId
                        info.claudeResumeCmd = "claude --resume \(claudeId)"
                        break
                    }
                }
            }

            // Determine command to re-run
            let command: String?
            if info.sessionType == SessionType.claude {
                if let resumeCmd = info.claudeResumeCmd {
                    command = resumeCmd
                } else {
                    command = "claude"
                }
            } else if info.sessionType == SessionType.deploy {
                command = buildDeployCommand()
            } else {
                command = nil
            }

            // Determine working directory
            let cwd: String
            if let wp = info.worktreePath, FileManager.default.fileExists(atPath: wp) {
                cwd = wp
            } else {
                cwd = projectRoot
            }

            // Spawn a new PTY
            guard let pty = try? PTYHandle.spawn(command: command, cwd: cwd, cols: cols, rows: rows) else {
                continue
            }

            // Restore session with the same ID
            info.pid = pty.pid
            info.state = SessionState.idle
            info.hasUnread = false

            let inner = SessionInner(info: info, pty: pty, claudeActive: info.claudeActive)
            inner.outputBuffer = saved.outputBuffer

            lock.lock()
            sessions[info.id] = inner
            lock.unlock()

            let reader = pty.makeReader()
            startReaderThread(sessionId: info.id, reader: reader)
        }

        // Prune worktrees not owned by any restored session
        pruneStaleWorktrees()

        notifySessionsChanged()
    }

    /// Remove leftover worktree directories that aren't tied to any active session.
    private func pruneStaleWorktrees() {
        lock.lock()
        let activePaths = Set(sessions.values.compactMap { s -> String? in
            guard s.info.branchName != nil else { return nil }
            return s.info.worktreePath
        })
        lock.unlock()

        DispatchQueue.global(qos: .utility).async {
            WorktreeManager.pruneStaleWorktrees(activeWorktreePaths: activePaths)
        }
    }

    private var autoSaveTimer: DispatchSourceTimer?
    private var idleStateTimer: DispatchSourceTimer?

    func startAutoSave() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            self?.saveAllSessions()
        }
        timer.resume()
        autoSaveTimer = timer

        startIdleStateTimer()
    }

    /// Periodic timer that updates state for sessions without recent output.
    /// Handles time-based transitions like working → idle (after 8s with no output).
    private func startIdleStateTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            self?.updateIdleStates()
        }
        timer.resume()
        idleStateTimer = timer
    }

    private func updateIdleStates() {
        let now = nowMs()
        var changed = false

        lock.lock()
        for (_, session) in sessions {
            let msSince = now - session.lastOutputTime
            guard msSince >= 2000 else { continue }

            // Use cached screen text (set by flush timer) or fall back to stripped raw output
            let text = session.cachedScreenText.isEmpty ? session.strippedTail : session.cachedScreenText

            let oldState = session.info.state
            session.info.state = StateDetector.shared.detectState(
                stripped: text,
                msSinceOutput: msSince,
                claudeActive: session.claudeActive
            )
            if oldState != session.info.state {
                session.info.stateChangedAt = now
                changed = true
            }
        }
        lock.unlock()

        if changed {
            notifySessionsChanged()
        }
    }

    /// Read the terminal screen buffer and update session state.
    /// Called from the flush timer after feeding data to the terminal view.
    /// Must run on main thread (terminal views are main-thread only).
    @discardableResult
    private func updateScreenState(sessionId: String, termView: TerminalView) -> Bool {
        let terminal = termView.getTerminal()
        var lines: [String] = []
        lines.reserveCapacity(terminal.rows)
        for row in 0..<terminal.rows {
            if let line = terminal.getLine(row: row) {
                lines.append(line.translateToString(trimRight: true))
            }
        }
        let screenText = lines.joined(separator: "\n")

        lock.lock()
        guard let session = sessions[sessionId] else {
            lock.unlock()
            return false
        }

        session.cachedScreenText = screenText

        // Detect claude active from screen (more accurate than raw output for TUI apps)
        let wasClaude = session.claudeActive
        session.claudeActive = StateDetector.shared.detectClaudeActive(
            in: screenText, wasActive: session.claudeActive
        )
        session.info.claudeActive = session.claudeActive

        if !wasClaude && session.claudeActive
            && session.info.customName == nil && session.info.aiName == nil {
            session.info.name = "Agent \(sessionId.prefix(8))"
        }

        let msSince = nowMs() - session.lastOutputTime
        let oldState = session.info.state
        session.info.state = StateDetector.shared.detectState(
            stripped: screenText,
            msSinceOutput: msSince,
            claudeActive: session.claudeActive
        )
        let changed = oldState != session.info.state
        if changed {
            session.info.stateChangedAt = nowMs()
            if session.info.state == .blocked
                && UserDefaults.standard.bool(forKey: "enableNotificationSounds") {
                DispatchQueue.main.async { NSSound.beep() }
            }
        }
        lock.unlock()
        return changed
    }

    // MARK: - PTY Reader

    private func startReaderThread(sessionId: String, reader: @escaping () -> Data?) {
        // Batch state shared between reader and flush timer
        let batchLock = NSLock()
        var batchBuf = Data()
        var done = false

        // Flush timer — fires every 16ms on main queue to push batched output to UI
        let flushTimer = DispatchSource.makeTimerSource(queue: .main)
        var lastSessionsNotify = DispatchTime.now()
        let sessionsInterval: UInt64 = 500_000_000 // 500ms in nanoseconds

        var lastScreenUpdate = DispatchTime.now()
        let screenUpdateInterval: UInt64 = 250_000_000 // 250ms — avoid running regex on every frame

        flushTimer.setEventHandler { [weak self] in
            let termView = self?.terminalViews[sessionId]

            batchLock.lock()
            // Only drain the batch buffer when the TerminalView exists.
            // TUI apps send critical setup sequences (alternate screen, colors)
            // early — if we drain before the view is ready, that data is lost
            // and the terminal shows a blank screen.
            let data: Data
            if termView != nil {
                data = batchBuf
                batchBuf = Data()
            } else {
                data = Data()
            }
            let isDone = done
            batchLock.unlock()

            if !data.isEmpty {
                if let termView = termView {
                    let bytes = [UInt8](data)
                    termView.feed(byteArray: ArraySlice(bytes))

                    // Throttle screen state detection — reading all terminal rows + regex
                    // is expensive and doesn't need to run on every 16ms frame.
                    let now = DispatchTime.now()
                    let screenElapsed = now.uptimeNanoseconds - lastScreenUpdate.uptimeNanoseconds
                    if screenElapsed >= screenUpdateInterval {
                        let stateChanged = self?.updateScreenState(sessionId: sessionId, termView: termView) ?? false
                        lastScreenUpdate = now

                        let notifyElapsed = now.uptimeNanoseconds - lastSessionsNotify.uptimeNanoseconds
                        if stateChanged || notifyElapsed >= sessionsInterval {
                            self?.notifySessionsChanged()
                            lastSessionsNotify = now
                        }
                    }
                } else {
                    // No terminal view yet — post periodic notifications so UI stays current
                    let now = DispatchTime.now()
                    let elapsed = now.uptimeNanoseconds - lastSessionsNotify.uptimeNanoseconds
                    if elapsed >= sessionsInterval {
                        self?.notifySessionsChanged()
                        lastSessionsNotify = now
                    }
                }
            }

            if isDone {
                flushTimer.cancel()
            }
        }
        flushTimer.schedule(deadline: .now(), repeating: .milliseconds(16))
        flushTimer.resume()

        // Reader thread — blocking reads from PTY
        Thread.detachNewThread { [weak self] in
            var utf8Pending = Data()

            while let chunk = reader() {
                guard let self = self else { break }

                // Prepend pending bytes
                var data: Data
                if utf8Pending.isEmpty {
                    data = chunk
                } else {
                    data = utf8Pending
                    data.append(chunk)
                    utf8Pending = Data()
                }

                // Find valid UTF-8 boundary
                let validLen = Self.findUTF8Boundary(data)
                if validLen < data.count {
                    utf8Pending = data.subdata(in: validLen..<data.count)
                }
                if validLen == 0 { continue }

                let validData = data.subdata(in: 0..<validLen)
                guard let text = String(data: validData, encoding: .utf8) else { continue }
                let now = nowMs()

                // Parse OSC title sequences from raw output before stripping ANSI.
                // This captures Claude's conversation UUID for all sessions (not just the visible one).
                self.parseOSCTitle(from: text, sessionId: sessionId)

                self.lock.lock()
                if let session = self.sessions[sessionId] {
                    // Append to output buffer
                    session.outputBuffer.append(text)
                    Self.trimBufferFront(&session.outputBuffer, maxLen: self.maxOutputBuffer)

                    session.lastOutputTime = now
                    session.info.lastActivity = now

                    session.info.hasUnread = true

                    // When no terminal view exists, we need ANSI-stripped text for
                    // state detection and last-line display. Once a view is attached,
                    // updateScreenState reads directly from the terminal buffer.
                    let needsFallback = self.terminalViews[sessionId] == nil
                    if needsFallback {
                        let tailStart = max(0, session.outputBuffer.count - 16384)
                        let tailIdx = session.outputBuffer.index(
                            session.outputBuffer.startIndex,
                            offsetBy: tailStart
                        )
                        let stripped = stripAnsi(String(session.outputBuffer[tailIdx...]))
                        session.strippedTail = stripped

                        // Update last line
                        let lastLineRaw = stripped.split(separator: "\n")
                            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                            ?? ""
                        let cleanLine = String(lastLineRaw)
                            .filter { !$0.isASCII || $0.asciiValue! >= 32 || $0 == "\t" }
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        session.info.lastLine = String(cleanLine.prefix(120))

                        // Parse Claude session ID
                        if session.info.claudeSessionId == nil {
                            if let sid = StateDetector.shared.parseClaudeSessionId(from: stripped) {
                                session.info.claudeSessionId = sid
                                session.info.claudeResumeCmd = "claude --resume \(sid)"
                            }
                        }

                        // Fallback state detection
                        session.claudeActive = StateDetector.shared.detectClaudeActive(
                            in: stripped, wasActive: session.claudeActive
                        )
                        session.info.claudeActive = session.claudeActive
                        session.info.state = StateDetector.shared.detectState(
                            stripped: stripped,
                            msSinceOutput: 0,
                            claudeActive: session.claudeActive
                        )
                    }
                }
                self.lock.unlock()

                // Append to batch
                batchLock.lock()
                batchBuf.append(validData)
                batchLock.unlock()
            }

            // EOF — mark done for flush timer
            batchLock.lock()
            done = true
            batchLock.unlock()

            // Mark session idle
            self?.lock.lock()
            self?.sessions[sessionId]?.info.state = .idle
            self?.lock.unlock()
            DispatchQueue.main.async { self?.notifySessionsChanged() }
        }
    }

    // MARK: - Helpers

    private func notifySessionsChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .sessionsChanged, object: nil)
        }
    }

    private static func findUTF8Boundary(_ data: Data) -> Int {
        var end = data.count
        while end > 0 && end > data.count - 4 {
            let b = data[end - 1]
            if b < 0x80 {
                break
            } else if b >= 0xC0 {
                let expected: Int
                if b >= 0xF0 { expected = 4 }
                else if b >= 0xE0 { expected = 3 }
                else { expected = 2 }
                if data.count - (end - 1) < expected {
                    end -= 1
                }
                break
            } else {
                end -= 1
            }
        }
        return end
    }

    private static func trimBufferFront(_ buf: inout String, maxLen: Int) {
        let byteCount = buf.utf8.count
        guard byteCount > maxLen else { return }
        let excess = byteCount - maxLen
        var idx = buf.utf8.index(buf.utf8.startIndex, offsetBy: excess)
        // Advance to character boundary
        while idx < buf.endIndex && !buf.utf8.indices.contains(idx) {
            idx = buf.utf8.index(after: idx)
        }
        buf = String(buf[idx...])
    }
}

private func nowMs() -> UInt64 {
    UInt64(Date().timeIntervalSince1970 * 1000)
}
