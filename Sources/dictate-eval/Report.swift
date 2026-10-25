import Foundation

/// Corpus-level numbers for one config (micro-averaged: total errors / total reference words).
struct ConfigSummary {
    let name: String
    let clipCount: Int
    let refWords: Int
    let normWER: Double?
    let normWERExcludingEmpty: Double?
    let casedWER: Double?
    let termHits: Int
    let termsExpected: Int
    let emptyRate: Double
    let hallucinationRate: Double
    let fallbackRate: Double
    let latencyP50: Double
    let latencyP95: Double
    let rtf: Double

    init(_ result: ConfigResult) {
        let clips = result.clips
        let scored = clips.filter { $0.score.refWords > 0 }
        let nonEmpty = scored.filter { !$0.score.empty }
        func rate(_ errors: (ClipResult) -> Int, _ words: (ClipResult) -> Int, _ set: [ClipResult]) -> Double? {
            let total = set.reduce(0) { $0 + words($1) }
            return total > 0 ? Double(set.reduce(0) { $0 + errors($1) }) / Double(total) : nil
        }
        name = result.config.name
        clipCount = clips.count
        refWords = scored.reduce(0) { $0 + $1.score.refWords }
        normWER = rate({ $0.score.normErrors }, { $0.score.refWords }, scored)
        normWERExcludingEmpty = rate({ $0.score.normErrors }, { $0.score.refWords }, nonEmpty)
        casedWER = rate({ $0.score.casedErrors }, { $0.score.casedRefWords }, scored)
        termHits = clips.reduce(0) { $0 + $1.score.termsHit }
        termsExpected = clips.reduce(0) { $0 + $1.score.termsExpected }
        emptyRate = scored.isEmpty ? 0 : Double(scored.filter { $0.score.empty }.count) / Double(scored.count)
        hallucinationRate =
            clips.isEmpty ? 0 : Double(clips.filter { $0.score.hallucination }.count) / Double(clips.count)
        fallbackRate = clips.isEmpty ? 0 : Double(clips.filter { $0.maxTemperature > 0 }.count) / Double(clips.count)
        let latencies = clips.filter { !$0.latencies.isEmpty }.map(\.latency)
        latencyP50 = Metrics.percentile(latencies, 50)
        latencyP95 = Metrics.percentile(latencies, 95)
        let audioTotal = clips.filter { !$0.latencies.isEmpty }.reduce(0) { $0 + $1.audioSeconds }
        rtf = audioTotal > 0 ? latencies.reduce(0, +) / audioTotal : 0
    }
}

enum Report {
    // MARK: CSV

    static let csvHeader = [
        "config", "clip", "audio_s", "ref_words", "hyp_words", "norm_errors", "norm_wer", "cased_errors",
        "cased_wer", "empty", "hallucination", "terms_expected", "terms_hit", "latency_s", "rtf", "max_temp",
        "temps", "fallbacks", "error", "reference", "hypothesis",
    ]

    static func csv(_ results: [ConfigResult]) -> String {
        var lines = [csvHeader.joined(separator: ",")]
        for result in results {
            for clip in result.clips {
                let s = clip.score
                let fields: [String] = [
                    result.config.name,
                    clip.clip.id,
                    String(format: "%.3f", clip.audioSeconds),
                    "\(s.refWords)",
                    "\(s.hypWords)",
                    "\(s.normErrors)",
                    s.normWER.map { String(format: "%.4f", $0) } ?? "",
                    "\(s.casedErrors)",
                    s.casedWER.map { String(format: "%.4f", $0) } ?? "",
                    s.empty ? "1" : "0",
                    s.hallucination ? "1" : "0",
                    "\(s.termsExpected)",
                    "\(s.termsHit)",
                    String(format: "%.3f", clip.latency),
                    String(format: "%.4f", clip.audioSeconds > 0 ? clip.latency / clip.audioSeconds : 0),
                    String(format: "%.1f", clip.maxTemperature),
                    clip.temperatures.map { String(format: "%.1f", $0) }.joined(separator: "|"),
                    "\(clip.fallbacks)",
                    clip.error ?? "",
                    clip.clip.reference,
                    clip.hypothesis,
                ]
                lines.append(fields.map(csvEscape).joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func csvEscape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Markdown

    static func summary(_ results: [ConfigResult], skipped: [String], runs: Int, timestamp: String) -> String {
        var out = "# dictate-eval \(timestamp)\n\n"
        guard let baseline = results.first else {
            return out + "No config finished.\n" + skippedSection(skipped)
        }
        let summaries = results.map(ConfigSummary.init)
        let refWords = summaries[0].refWords
        out += "\(baseline.clips.count) clips, \(refWords) reference words, \(runs) timed run(s) per clip "
        out += "after one untimed warm-up decode. Baseline for deltas: **\(baseline.config.name)**.\n\n"
        out += "Corpus of this size: 1-2 WER points are noise. Compare per-clip deltas below, "
        out += "and judge empty outputs separately from WER.\n\n"

        out += "| config | nWER | nWER excl. empty | cased WER | term recall | empty | halluc. | fallback "
        out += "| lat p50 (s) | lat p95 (s) | RTF | load (s) |\n"
        out += "|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for (result, s) in zip(results, summaries) {
            let recall = s.termsExpected > 0 ? "\(s.termHits)/\(s.termsExpected)" : "-"
            out += "| \(s.name) | \(pct(s.normWER)) | \(pct(s.normWERExcludingEmpty)) | \(pct(s.casedWER)) "
            out += "| \(recall) | \(pct(s.emptyRate)) | \(pct(s.hallucinationRate)) | \(pct(s.fallbackRate)) "
            out += "| \(String(format: "%.2f", s.latencyP50)) | \(String(format: "%.2f", s.latencyP95)) "
            out += "| \(String(format: "%.3f", s.rtf)) | \(String(format: "%.1f", result.loadSeconds)) |\n"
        }
        out += "\nnWER = Whisper-style normalized WER; cased WER keeps case, trims punctuation. "
        out += "fallback = clips whose final segment temperature > 0. RTF = total latency / total audio.\n"

        out += "\n## Configs\n\n"
        for result in results {
            out += "- **\(result.config.name)**: \(result.config.summary)\n"
        }

        if results.count > 1 {
            out += "\n## Paired deltas vs \(baseline.config.name)\n\n"
            out += "Per-clip normalized WER, config minus baseline (negative = better).\n\n"
            out += "| config | mean delta (pts) | better | worse | same |\n|---|---|---|---|---|\n"
            for result in results.dropFirst() {
                let deltas = pairedDeltas(baseline: baseline, other: result)
                let mean = deltas.isEmpty ? 0 : deltas.reduce(0) { $0 + $1.delta } / Double(deltas.count) * 100
                let better = deltas.filter { $0.delta < -1e-9 }.count
                let worse = deltas.filter { $0.delta > 1e-9 }.count
                out += "| \(result.config.name) | \(String(format: "%+.1f", mean)) | \(better) | \(worse) "
                out += "| \(deltas.count - better - worse) |\n"
            }
            for result in results.dropFirst() {
                let sorted = pairedDeltas(baseline: baseline, other: result).sorted { $0.delta > $1.delta }
                let regressions = sorted.prefix(3).filter { $0.delta > 1e-9 }
                let gains = sorted.reversed().prefix(3).filter { $0.delta < -1e-9 }
                if regressions.isEmpty && gains.isEmpty { continue }
                out += "\n**\(result.config.name)** biggest moves:\n\n"
                for entry in gains {
                    out += "- \(entry.clip) \(String(format: "%+.0f", entry.delta * 100)) pts (better)\n"
                }
                for entry in regressions {
                    out += "- \(entry.clip) \(String(format: "%+.0f", entry.delta * 100)) pts (worse)\n"
                }
            }
        }

        out += "\n## Empty outputs\n\n"
        for result in results {
            let empties = result.clips.filter { $0.score.empty }.map(\.clip.id)
            out += "- \(result.config.name): \(empties.isEmpty ? "none" : empties.joined(separator: ", "))\n"
        }
        let failures = results.flatMap { result in
            result.clips.compactMap { clip in clip.error.map { "\(result.config.name) \(clip.clip.id): \($0)" } }
        }
        if !failures.isEmpty {
            out += "\n## Errors\n\n" + failures.map { "- \($0)\n" }.joined()
        }
        return out + skippedSection(skipped)
    }

    private static func skippedSection(_ skipped: [String]) -> String {
        skipped.isEmpty ? "" : "\n## Skipped configs\n\n" + skipped.map { "- \($0)\n" }.joined()
    }

    struct PairedDelta {
        let clip: String
        let delta: Double
    }

    static func pairedDeltas(baseline: ConfigResult, other: ConfigResult) -> [PairedDelta] {
        let base = Dictionary(uniqueKeysWithValues: baseline.clips.map { ($0.clip.id, $0.score.normWER) })
        return other.clips.compactMap { clip in
            guard let b = base[clip.clip.id] ?? nil, let o = clip.score.normWER else { return nil }
            return PairedDelta(clip: clip.clip.id, delta: o - b)
        }
    }

    private static func pct(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0 * 100) } ?? "-"
    }
}
