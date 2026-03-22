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

    /// Deploy agent command — uses allowedTools to grant full bash and tool access
    static let deployCommand = "claude" +
        " --allowedTools" +
        " 'Bash(*)'" +
        " Read Grep Glob Edit Write WebFetch WebSearch 'mcp__*'" +
        #" --system-prompt "You are a deployment agent. Follow this workflow:"# +
        #" 1) WORKTREES: Check all local worktrees for uncommitted changes by running: for wt in $(git worktree list --porcelain | grep '^worktree ' | awk '{print $2}'); do s=$(git -C \"$wt\" status --short 2>/dev/null | grep -v node_modules | grep -v '.package-lock'); if [ -n \"$s\" ]; then echo \"Worktree $wt:\"; echo \"$s\"; fi; done. Review any uncommitted changes — look at the diffs to understand what each change does, then commit and merge them into the main branch."# +
        #" 2) BUILD: Run npm run build. If it fails, fix the issues and rebuild until it passes."# +
        #" 3) PUSH: git add, commit, and push changes to the remote."# +
        #" 4) CI: Check GitHub Actions status with 'gh run list --limit 5' and 'gh run view <id>'. If any checks fail, read the logs with 'gh run view <id> --log-failed', fix the issues, push again, and re-check. Iterate until CI passes."# +
        #" 5) DEPLOY: Verify deploy status using any available Render MCP tools. If the deploy fails, check the logs, fix issues, and redeploy. Iterate until the deploy succeeds."# +
        #" 6) SUMMARY: When everything is green, print a deployment summary with: the branch/commit deployed, a bullet list of features and changes included (derived from commit messages and diffs), CI status, and deploy status. Keep it concise."# +
        #" Be concise throughout. Focus on getting the deploy done end-to-end.""#

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
        lock.lock()
        let now = nowMs()

        // Update states based on timing
        for session in sessions.values {
            let msSince = now - session.lastOutputTime
            let newState = StateDetector.shared.detectState(
                stripped: session.strippedTail,
                msSinceOutput: msSince,
                claudeActive: session.claudeActive
            )
            session.info.state = newState
        }

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
                command = Self.deployCommand
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

    func startAutoSave() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            self?.saveAllSessions()
        }
        timer.resume()
        autoSaveTimer = timer
    }

    // MARK: - PTY Reader

    private func startReaderThread(sessionId: String, reader: @escaping () -> Data?) {
        // Batch state shared between reader and flush timer
        let batchLock = NSLock()
        var batchBuf = Data()
        var batchStateChanged = false
        var done = false

        // Flush timer — fires every 16ms on main queue to push batched output to UI
        let flushTimer = DispatchSource.makeTimerSource(queue: .main)
        var lastSessionsNotify = DispatchTime.now()
        let sessionsInterval: UInt64 = 500_000_000 // 500ms in nanoseconds

        flushTimer.setEventHandler { [weak self] in
            batchLock.lock()
            let data = batchBuf
            batchBuf = Data()
            let stateChanged = batchStateChanged
            batchStateChanged = false
            let isDone = done
            batchLock.unlock()

            if !data.isEmpty {
                // Feed directly to the session's TerminalView
                if let termView = self?.terminalViews[sessionId] {
                    let bytes = [UInt8](data)
                    termView.feed(byteArray: ArraySlice(bytes))
                }

                // Post notification for sidebar/other UI updates
                let now = DispatchTime.now()
                let elapsed = now.uptimeNanoseconds - lastSessionsNotify.uptimeNanoseconds
                if stateChanged || elapsed >= sessionsInterval {
                    self?.notifySessionsChanged()
                    lastSessionsNotify = now
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

                var stateChanged = false

                self.lock.lock()
                if let session = self.sessions[sessionId] {
                    // Append to output buffer
                    session.outputBuffer.append(text)
                    Self.trimBufferFront(&session.outputBuffer, maxLen: self.maxOutputBuffer)

                    session.lastOutputTime = now
                    session.info.lastActivity = now

                    // Strip ANSI from last 4KB for state detection
                    let tailStart = max(0, session.outputBuffer.count - 4096)
                    let tailIdx = session.outputBuffer.index(
                        session.outputBuffer.startIndex,
                        offsetBy: tailStart
                    )
                    let stripped = stripAnsi(String(session.outputBuffer[tailIdx...]))
                    session.strippedTail = stripped

                    // Update last line — use stripped text (no ANSI)
                    let lastLineRaw = stripped.split(separator: "\n")
                        .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                        ?? ""
                    // Remove any remaining control chars and trim
                    let cleanLine = String(lastLineRaw)
                        .filter { !$0.isASCII || $0.asciiValue! >= 32 || $0 == "\t" }
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    session.info.lastLine = String(cleanLine.prefix(120))

                    // Detect Claude active
                    let wasClaude = session.claudeActive
                    session.claudeActive = StateDetector.shared.detectClaudeActive(
                        in: stripped, wasActive: session.claudeActive
                    )
                    session.info.claudeActive = session.claudeActive

                    if !wasClaude && session.claudeActive
                        && session.info.customName == nil && session.info.aiName == nil {
                        session.info.name = "Agent \(sessionId.prefix(8))"
                    }

                    // Detect state
                    let oldState = session.info.state
                    session.info.state = StateDetector.shared.detectState(
                        stripped: stripped,
                        msSinceOutput: 0,
                        claudeActive: session.claudeActive
                    )
                    if oldState != session.info.state {
                        session.info.stateChangedAt = now
                        stateChanged = true

                        if session.info.state == .blocked
                            && UserDefaults.standard.bool(forKey: "enableNotificationSounds") {
                            DispatchQueue.main.async {
                                NSSound.beep()
                            }
                        }
                    }

                    // Parse Claude session ID
                    if session.info.claudeSessionId == nil {
                        if let sid = StateDetector.shared.parseClaudeSessionId(from: stripped) {
                            session.info.claudeSessionId = sid
                            session.info.claudeResumeCmd = "claude --resume \(sid)"
                        }
                    }

                    session.info.hasUnread = true
                }
                self.lock.unlock()

                // Append to batch
                batchLock.lock()
                batchBuf.append(validData)
                if stateChanged { batchStateChanged = true }
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
        guard buf.utf8.count > maxLen else { return }
        let excess = buf.utf8.count - maxLen
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
