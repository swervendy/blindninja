import Foundation

/// Persists session metadata and terminal output to disk for restore on relaunch.
/// Storage: ~/Library/Application Support/BlindNinja/sessions/
final class SessionPersistence {
    static let shared = SessionPersistence()

    private let sessionsDir: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        sessionsDir = appSupport.appendingPathComponent("BlindNinja/sessions")
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    }

    // MARK: - Data structures

    private struct Manifest: Codable {
        let projectRoot: String
        let sessions: [SessionInfo]
    }

    // MARK: - Save

    func saveAll(projectRoot: String, sessions: [(info: SessionInfo, outputBuffer: String)]) {
        // Filter out archived sessions
        let active = sessions.filter { !$0.info.archived }

        // Write manifest
        let manifest = Manifest(projectRoot: projectRoot, sessions: active.map { $0.info })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(manifest) {
            try? data.write(to: sessionsDir.appendingPathComponent("manifest.json"), options: .atomic)
        }

        // Write output buffers
        for session in active {
            let file = sessionsDir.appendingPathComponent("\(session.info.id).output")
            try? session.outputBuffer.write(to: file, atomically: true, encoding: .utf8)
        }

        // Clean up output files for sessions no longer in the manifest
        let activeIds = Set(active.map { $0.info.id })
        if let files = try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "output" {
                let id = file.deletingPathExtension().lastPathComponent
                if !activeIds.contains(id) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    // MARK: - Load

    func loadAll() -> (projectRoot: String?, sessions: [(info: SessionInfo, outputBuffer: String)]) {
        let manifestURL = sessionsDir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return (nil, [])
        }

        var result: [(info: SessionInfo, outputBuffer: String)] = []
        for info in manifest.sessions {
            let outputFile = sessionsDir.appendingPathComponent("\(info.id).output")
            let output = (try? String(contentsOf: outputFile, encoding: .utf8)) ?? ""
            result.append((info: info, outputBuffer: output))
        }

        return (manifest.projectRoot, result)
    }

    // MARK: - Cleanup

    func clearAll() {
        try? FileManager.default.removeItem(at: sessionsDir)
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    }
}
