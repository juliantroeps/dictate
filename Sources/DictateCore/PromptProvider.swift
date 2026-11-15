import Foundation

public enum PromptProvider {
    static let promptFilePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".dictate/prompt.txt")

    // WhisperKit 0.15 disables the prefill KV-cache whenever promptTokens are
    // set (TextDecoder.swift:354 TODO), so every prompt token is decoded
    // token-by-token on EVERY dictation. Keep this short - only genuinely
    // misrecognized, high-value terms.
    public static let defaultPrompt = """
        Software engineer dictating about web development. Preserve casing: \
        Next.js, TypeScript, GraphQL, PostgreSQL, MongoDB, Kubernetes, \
        Terraform, Supabase, Prisma, pnpm, Cursor, Claude.
        """

    public static func resolve() -> String {
        resolve(from: promptFilePath)
    }

    /// Vocabulary list for engines biased by phrases rather than a prompt (eval-only SpeechAnalyzer).
    public static let defaultTerms = [
        "Next.js", "TypeScript", "GraphQL", "PostgreSQL", "MongoDB", "Kubernetes",
        "Terraform", "Supabase", "Prisma", "pnpm", "Cursor", "Claude",
    ]

    /// One term per line, `#` comments.
    public static func parseTerms(contentsOf url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func resolve(from promptURL: URL) -> String {
        if let fileContents = try? String(contentsOf: promptURL, encoding: .utf8) {
            let trimmed = fileContents.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                AppLogger.transcription.debug("Using custom prompt file")
                return trimmed
            }
        }
        AppLogger.transcription.debug("Using default prompt")
        return defaultPrompt
    }
}
