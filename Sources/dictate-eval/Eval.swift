import Foundation

private let usage = """
    dictate-eval - offline transcription eval for dictate (WhisperKit, same engine + options as the app)

    Usage: dictate-eval [options] [config ...]

      config            config name (eval/configs/<name>.json) or path to a .json file;
                        none given = every *.json in the configs dir, sorted by name.
                        The first config is the baseline for paired deltas.

    Options:
      --clips DIR       NNN.wav + NNN.ref.txt pairs        (default eval/clips)
      --configs DIR     config JSON files                  (default eval/configs)
      --terms FILE      case-sensitive jargon, one/line    (default eval/terms.txt)
      --out DIR         results parent dir                 (default eval/out)
      --runs N          timed decodes per clip, median     (default 1)
      -h, --help

    Writes <out>/<timestamp>/results.csv and summary.md. Use a release build for latency numbers:
    scripts/eval.sh [options] [config ...]
    """

struct EvalOptions {
    var clips = "eval/clips"
    var configs = "eval/configs"
    var terms = "eval/terms.txt"
    var out = "eval/out"
    var runs = 1
    var configArguments: [String] = []

    enum ParseError: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            switch self {
            case .message(let text): text
            }
        }
    }

    /// Returns nil when help was requested.
    static func parse(_ arguments: [String]) throws -> EvalOptions? {
        var options = EvalOptions()
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            func value() throws -> String {
                guard let next = iterator.next() else { throw ParseError.message("\(argument) needs a value") }
                return next
            }
            switch argument {
            case "-h", "--help": return nil
            case "--clips": options.clips = try value()
            case "--configs": options.configs = try value()
            case "--terms": options.terms = try value()
            case "--out": options.out = try value()
            case "--runs":
                guard let runs = Int(try value()), runs >= 1 else {
                    throw ParseError.message("--runs must be a positive integer")
                }
                options.runs = runs
            default:
                if argument.hasPrefix("-") { throw ParseError.message("unknown option \(argument)") }
                options.configArguments.append(argument)
            }
        }
        return options
    }

    func configURLs() throws -> [URL] {
        let directory = URL(fileURLWithPath: configs)
        if configArguments.isEmpty {
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        return configArguments.map { argument in
            argument.hasSuffix(".json")
                ? URL(fileURLWithPath: argument) : directory.appendingPathComponent("\(argument).json")
        }
    }
}

@main
enum DictateEval {
    static func main() async {
        do {
            guard let options = try EvalOptions.parse(Array(CommandLine.arguments.dropFirst())) else {
                print(usage)
                return
            }
            try await run(options)
        } catch {
            log("error: \(error)")
            exit(1)
        }
    }

    static func run(_ options: EvalOptions) async throws {
        let clips = try Runner.loadClips(from: URL(fileURLWithPath: options.clips))
        guard !clips.isEmpty else {
            throw EvalOptions.ParseError.message("no NNN.wav + NNN.ref.txt pairs in \(options.clips)")
        }
        let configURLs = try options.configURLs()
        guard !configURLs.isEmpty else {
            throw EvalOptions.ParseError.message("no config .json files in \(options.configs)")
        }
        let configs = try configURLs.map(EvalConfig.load)
        let terms = Runner.loadTerms(from: URL(fileURLWithPath: options.terms))
        log("\(clips.count) clips, \(configs.count) config(s), \(terms.count) term(s), \(options.runs) run(s)/clip")

        var results: [ConfigResult] = []
        var skipped: [String] = []
        for config in configs {
            do {
                results.append(try await Runner.run(config: config, clips: clips, terms: terms, runs: options.runs))
            } catch {
                log("[\(config.name)] failed: \(error)")
                skipped.append("\(config.name): \(error)")
            }
        }

        let stamp = timestamp()
        let outDirectory = URL(fileURLWithPath: options.out).appendingPathComponent(stamp)
        try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
        let summary = Report.summary(results, skipped: skipped, runs: options.runs, timestamp: stamp)
        try Report.csv(results).write(
            to: outDirectory.appendingPathComponent("results.csv"), atomically: true, encoding: .utf8)
        try summary.write(to: outDirectory.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        print(summary)
        print("Wrote \(outDirectory.path)/{results.csv,summary.md}")
        if results.isEmpty { exit(1) }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
