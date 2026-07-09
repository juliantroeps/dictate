import Foundation

enum PromptProvider {
    static let promptFilePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".dictate/prompt.txt")

    // WhisperKit 0.15 disables the prefill KV-cache whenever promptTokens are
    // set (TextDecoder.swift:354 TODO), so every prompt token is decoded
    // token-by-token on EVERY dictation. Keep this short - only genuinely
    // misrecognized, high-value terms.
    static let defaultPrompt = """
        Software engineer dictating about web development. Preserve casing: \
        Next.js, TypeScript, GraphQL, PostgreSQL, MongoDB, Kubernetes, \
        Terraform, Supabase, Prisma, pnpm, Cursor, Claude.
        """

    static func resolve() -> String {
        resolve(from: promptFilePath)
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
