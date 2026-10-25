import DictateCore
import Foundation
import WhisperKit

struct Clip {
    let id: String
    let url: URL
    let reference: String
}

struct ClipResult {
    let clip: Clip
    let audioSeconds: Double
    let hypothesis: String
    /// Wall time of every timed run; the first run's output is what gets scored.
    let latencies: [Double]
    let temperatures: [Float]
    let fallbacks: Int
    let error: String?
    let score: ClipScore

    var latency: Double { Metrics.percentile(latencies, 50) }
    var maxTemperature: Float { temperatures.max() ?? 0 }
}

struct ConfigResult {
    let config: EvalConfig
    let loadSeconds: Double
    let clips: [ClipResult]
}

enum Runner {
    /// `NNN.wav` + `NNN.ref.txt` pairs, sorted by name. Clips without a reference are skipped with a warning.
    static func loadClips(from directory: URL) throws -> [Clip] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var clips: [Clip] = []
        for url in files {
            let id = url.deletingPathExtension().lastPathComponent
            let refURL = directory.appendingPathComponent("\(id).ref.txt")
            guard let reference = try? String(contentsOf: refURL, encoding: .utf8) else {
                log("warning: \(id).wav has no \(id).ref.txt, skipping")
                continue
            }
            clips.append(Clip(id: id, url: url, reference: reference.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return clips
    }

    /// One term per line; blank lines and `#` comments ignored.
    static func loadTerms(from url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func run(config: EvalConfig, clips: [Clip], terms: [String], runs: Int) async throws -> ConfigResult {
        let engine = config.makeEngine()
        log("[\(config.name)] loading \(config.model) (first use of a model may download or compile for a while)")
        let loadStart = ContinuousClock.now
        try await engine.prepare()
        let loadSeconds = seconds(since: loadStart)

        let audio = try clips.map { try AudioProcessor.loadAudioAsFloatArray(fromPath: $0.url.path) }

        // First decode after load pays one-time CoreML/ANE costs; keep it out of the latency numbers.
        if let first = audio.first {
            _ = try? await engine.transcribeDetailed(audioSamples: first)
        }

        var results: [ClipResult] = []
        for (clip, samples) in zip(clips, audio) {
            var latencies: [Double] = []
            var detail: TranscriptionDetail?
            var failure: String?
            for _ in 0..<runs {
                let start = ContinuousClock.now
                do {
                    let current = try await engine.transcribeDetailed(audioSamples: samples)
                    latencies.append(seconds(since: start))
                    detail = detail ?? current
                } catch {
                    failure = String(describing: error)
                    break
                }
            }
            let hypothesis = detail?.text ?? ""
            let audioSeconds = Double(samples.count) / 16_000
            log(
                "[\(config.name)] \(clip.id) \(String(format: "%.1fs audio", audioSeconds)) -> "
                    + "\(String(format: "%.2fs", latencies.first ?? 0)) \(hypothesis.isEmpty ? "(empty)" : "")")
            results.append(
                ClipResult(
                    clip: clip,
                    audioSeconds: audioSeconds,
                    hypothesis: hypothesis,
                    latencies: latencies,
                    temperatures: detail?.segmentTemperatures ?? [],
                    fallbacks: detail?.fallbackCount ?? 0,
                    error: failure,
                    score: ClipScore.score(reference: clip.reference, hypothesis: hypothesis, terms: terms)))
        }
        await engine.unload()
        return ConfigResult(config: config, loadSeconds: loadSeconds, clips: results)
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let parts = start.duration(to: .now).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
