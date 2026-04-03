import Foundation

enum PromptProvider {
    static let promptFilePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".dictate/prompt.txt")

    static let defaultPrompt = """
        Software engineer dictating about web development and infrastructure. \
        Abbreviations spoken letter-by-letter: SSR, SSG, ISR, CI/CD, JWT, \
        gRPC, tRPC, CTV, DNS, CDN, ORM, SDK, AWS. \
        Preserve casing: Next.js, Node.js, FastAPI, GraphQL, TypeScript, \
        PostgreSQL, Tailwind CSS, OpenAPI, PromQL, OpenTelemetry. \
        Terms: pnpm, React, Svelte, Deno, Bun, Drizzle, Prisma, Supabase, \
        Vite, Vitest, Terraform, Caddy, Turbopack, esbuild, \
        Hetzner, DynamoDB, MonogDB, Kubernetes, \
        Cursor, Claude, OpenAI, ChatGPT.
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
