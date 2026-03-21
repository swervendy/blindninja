import Foundation

/// Claude API calls for session auto-naming and QA summaries.
final class AIService {
    static let shared = AIService()

    private let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private let apiVersion = "2023-06-01"

    private init() {}

    /// Get the API key from environment or config file.
    func getApiKey() -> String? {
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            return key
        }
        return loadApiKeyFromConfig()
    }

    func hasApiKey() -> Bool {
        getApiKey() != nil
    }

    /// Save API key to ~/.blind-ninja/config.json
    func saveApiKey(_ key: String) throws {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".blind-ninja")

        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        // Set directory permissions to 700
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: configDir.path
        )

        let configFile = configDir.appendingPathComponent("config.json")
        let config: [String: Any] = ["api_key": key]
        let data = try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
        try data.write(to: configFile)

        // Set file permissions to 600
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configFile.path
        )
    }

    /// Generate a short name for a session using Haiku (cheap + fast).
    func generateName(outputBuffer: String) async throws -> String {
        guard let apiKey = getApiKey() else {
            throw AIServiceError.noApiKey
        }

        let lastChars = String(outputBuffer.suffix(2000))
        let systemPrompt = """
        You are a naming assistant. Given terminal output, generate a concise 2-5 word name \
        that describes what this terminal session is doing. Return ONLY the name, nothing else. \
        No quotes, no punctuation, no explanation.
        """

        return try await callAPI(
            apiKey: apiKey,
            model: "claude-haiku-4-5-20251001",
            systemPrompt: systemPrompt,
            userMessage: lastChars,
            maxTokens: 20
        )
    }

    /// Generate a QA summary from multiple session outputs.
    func generateQASummary(sessions: [(name: String, output: String)]) async throws -> String {
        guard let apiKey = getApiKey() else {
            throw AIServiceError.noApiKey
        }

        let combined = sessions.map { "=== \($0.name) ===\n\($0.output.suffix(3000))" }
            .joined(separator: "\n\n")

        let systemPrompt = """
        You are a QA analyst reviewing terminal sessions from AI coding agents. \
        Summarize what each agent did, what changes were made, and flag any potential issues. \
        Be concise and actionable.
        """

        return try await callAPI(
            apiKey: apiKey,
            model: "claude-sonnet-4-20250514",
            systemPrompt: systemPrompt,
            userMessage: combined,
            maxTokens: 1024
        )
    }

    // MARK: - Private

    private func callAPI(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userMessage: String,
        maxTokens: Int
    ) async throws -> String {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userMessage]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AIServiceError.apiError(statusCode: statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw AIServiceError.invalidResponse
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadApiKeyFromConfig() -> String? {
        let configFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".blind-ninja/config.json")
        guard let data = try? Data(contentsOf: configFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = json["api_key"] as? String, !key.isEmpty else {
            return nil
        }
        return key
    }
}

enum AIServiceError: Error, LocalizedError {
    case noApiKey
    case apiError(statusCode: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noApiKey: return "No API key configured"
        case .apiError(let code): return "API error: HTTP \(code)"
        case .invalidResponse: return "Invalid API response"
        }
    }
}
