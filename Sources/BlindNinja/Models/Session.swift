import Foundation

enum SessionType: String, Codable {
    case claude
    case deploy
    case shell
}

enum SessionState: String, Codable {
    case idle
    case working
    case waiting
    case blocked
    case new
}

struct SessionInfo: Identifiable, Codable {
    let id: String
    var name: String
    var aiName: String?
    var customName: String?
    var state: SessionState
    var lastActivity: UInt64
    var lastLine: String
    var claudeSessionId: String?
    var claudeResumeCmd: String?
    var hasUnread: Bool
    var stateChangedAt: UInt64
    var worktreePath: String?
    var branchName: String?
    var pid: pid_t
    var claudeActive: Bool
    var createdAt: UInt64
    var starred: Bool
    var archived: Bool
    var sortOrder: UInt32
    var sessionType: SessionType
}
