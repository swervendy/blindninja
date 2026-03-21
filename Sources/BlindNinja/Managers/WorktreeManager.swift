import Foundation

/// Git worktree management — create isolated branch checkouts for agent sessions.
enum WorktreeManager {
    static func createWorktree(repoPath: String, branchName: String? = nil) throws -> (path: String, branch: String) {
        let branch = branchName ?? "claude/\(Int(Date().timeIntervalSince1970))"
        let safeBranch = branch.replacingOccurrences(of: "/", with: "-")

        // Determine repo name from path
        let repoName = URL(fileURLWithPath: repoPath).lastPathComponent

        let worktreeBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".blind-ninja/worktrees/\(repoName)")
        try FileManager.default.createDirectory(at: worktreeBase, withIntermediateDirectories: true)

        let worktreePath = worktreeBase.appendingPathComponent(safeBranch).path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["worktree", "add", "-b", branch, worktreePath]
        process.currentDirectoryURL = URL(fileURLWithPath: repoPath)

        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = pipe.fileHandleForReading.readDataToEndOfFile()
            let err = String(data: errData, encoding: .utf8) ?? "Unknown error"
            throw WorktreeError.createFailed(err)
        }

        return (worktreePath, branch)
    }

    static func removeWorktree(repoPath: String, worktreePath: String) {
        let remove = Process()
        remove.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        remove.arguments = ["worktree", "remove", "--force", worktreePath]
        remove.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        try? remove.run()
        remove.waitUntilExit()

        // Also delete the branch
        let branchName = URL(fileURLWithPath: worktreePath).lastPathComponent
        let deleteBranch = Process()
        deleteBranch.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        deleteBranch.arguments = ["branch", "-D", branchName]
        deleteBranch.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        try? deleteBranch.run()
        deleteBranch.waitUntilExit()
    }
}

enum WorktreeError: Error, LocalizedError {
    case createFailed(String)

    var errorDescription: String? {
        switch self {
        case .createFailed(let msg): return "Worktree creation failed: \(msg)"
        }
    }
}
