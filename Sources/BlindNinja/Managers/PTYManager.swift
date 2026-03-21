import Foundation
import Darwin

/// Handle to a running PTY process — direct forkpty(), no abstraction layers.
final class PTYHandle {
    let masterFd: Int32
    let pid: pid_t
    private var alive = true

    private init(masterFd: Int32, pid: pid_t) {
        self.masterFd = masterFd
        self.pid = pid
    }

    /// Spawn a new PTY process.
    ///
    /// - Parameters:
    ///   - command: Optional command to run (e.g. "claude"). If nil, spawns user's shell.
    ///   - cwd: Working directory. If nil, inherits parent's.
    ///   - cols: Terminal width in columns.
    ///   - rows: Terminal height in rows.
    /// - Returns: A PTYHandle for the running process.
    static func spawn(
        command: String? = nil,
        cwd: String? = nil,
        cols: UInt16 = 120,
        rows: UInt16 = 30
    ) throws -> PTYHandle {
        var masterFd: Int32 = 0
        var winsize = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        let pid = forkpty(&masterFd, nil, nil, &winsize)

        if pid < 0 {
            throw PTYError.forkFailed(errno: errno)
        }

        if pid == 0 {
            // ── Child process ──

            // Raise file descriptor limit
            var rlim = rlimit(rlim_cur: 10240, rlim_max: 10240)
            setrlimit(RLIMIT_NOFILE, &rlim)

            // Set working directory
            if let cwd = cwd {
                chdir(cwd)
            }

            // Set environment
            setenv("TERM", "xterm-256color", 1)
            setenv("LANG", "en_US.UTF-8", 1)
            setenv("LC_ALL", "en_US.UTF-8", 1)
            setenv("COLORTERM", "truecolor", 1)

            // Build argv
            if let command = command {
                // Run command via login shell: $SHELL -l -i -c "command"
                let argv: [UnsafeMutablePointer<CChar>?] = [
                    strdup(shell),
                    strdup("-l"),
                    strdup("-i"),
                    strdup("-c"),
                    strdup(command),
                    nil
                ]
                execv(shell, argv)
            } else {
                // Interactive login shell: $SHELL -l -i
                let argv: [UnsafeMutablePointer<CChar>?] = [
                    strdup(shell),
                    strdup("-l"),
                    strdup("-i"),
                    nil
                ]
                execv(shell, argv)
            }

            // If execv returns, something went wrong
            _exit(1)
        }

        // ── Parent process ──

        // Set non-blocking would hurt batching — keep blocking reads in the reader thread.
        // The reader thread is dedicated per session, so blocking is fine.

        return PTYHandle(masterFd: masterFd, pid: pid)
    }

    /// Write data (keystrokes) to the PTY.
    func write(_ data: Data) {
        guard alive else { return }
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var written = 0
            let total = data.count
            while written < total {
                let n = Darwin.write(masterFd, base + written, total - written)
                if n <= 0 { break }
                written += n
            }
        }
    }

    /// Write a string to the PTY.
    func write(_ string: String) {
        if let data = string.data(using: .utf8) {
            write(data)
        }
    }

    /// Resize the PTY.
    func resize(cols: UInt16, rows: UInt16) {
        guard alive else { return }
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFd, UInt(TIOCSWINSZ), &ws)
    }

    /// Kill the child process.
    func kill() {
        guard alive else { return }
        alive = false
        Darwin.kill(pid, SIGTERM)

        // Reap after a short delay — give it time to exit gracefully
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [pid] in
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
        }
    }

    /// Create a reader that reads from the PTY master fd.
    /// Returns a closure that blocks and reads up to bufSize bytes, returning the data.
    /// Returns nil on EOF or error.
    func makeReader(bufSize: Int = 16384) -> () -> Data? {
        let fd = masterFd
        return {
            var buffer = [UInt8](repeating: 0, count: bufSize)
            let n = Darwin.read(fd, &buffer, bufSize)
            if n <= 0 { return nil }
            return Data(buffer[..<n])
        }
    }

    deinit {
        kill()
        close(masterFd)
    }
}

enum PTYError: Error, LocalizedError {
    case forkFailed(errno: Int32)

    var errorDescription: String? {
        switch self {
        case .forkFailed(let e):
            return "forkpty failed: \(String(cString: strerror(e)))"
        }
    }
}
