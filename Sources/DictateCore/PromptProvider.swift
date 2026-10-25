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

    /// WhisperKit 0.15 returns "" for the multilingual large-v3 turbo family when prompt tokens
    /// are set: its decode loop honors an `<|endoftext|>` sampled while the prompt is force-fed.
    /// Measured empty on 100% of clips for _547MB and _turbo_632MB; the rest of the family is
    /// assumed alike. Fixed upstream in argmax-oss-swift 1.1.0.
    static let promptlessModelPrefixes = ["openai_whisper-large-v3-v20240930"]

    public static func supportsPrompt(model: String) -> Bool {
        !promptlessModelPrefixes.contains { model.hasPrefix($0) }
    }

    /// The prompt to condition `model` on, or nil when it can't take one.
    public static func resolve(forModel model: String) -> String? {
        supportsPrompt(model: model) ? resolve() : nil
    }

    public static func resolve() -> String {
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
