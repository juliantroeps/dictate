import Foundation

enum Metrics {
    /// Word-level Levenshtein distance (substitutions + deletions + insertions).
    static func editDistance(_ ref: [String], _ hyp: [String]) -> Int {
        if ref.isEmpty { return hyp.count }
        if hyp.isEmpty { return ref.count }
        var previous = Array(0...hyp.count)
        var current = [Int](repeating: 0, count: hyp.count + 1)
        for i in 1...ref.count {
            current[0] = i
            for j in 1...hyp.count {
                let substitution = previous[j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        return previous[hyp.count]
    }

    /// Whitespace tokens with surrounding punctuation trimmed, case kept ("Next.js." -> "Next.js").
    /// Scores casing and jargon spelling while ignoring sentence punctuation.
    static func casedWords(_ text: String) -> [String] {
        let trim = CharacterSet.punctuationCharacters.union(.symbols)
        return text.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: trim) }
            .filter { !$0.isEmpty }
    }

    /// Case-sensitive occurrence of `term` not embedded in a longer alphanumeric run ("Go" is not in "Google").
    static func contains(_ text: String, term: String) -> Bool {
        guard !term.isEmpty else { return false }
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: term, options: .literal, range: searchRange) {
            let before = found.lowerBound == text.startIndex ? nil : text[text.index(before: found.lowerBound)]
            let after = found.upperBound == text.endIndex ? nil : text[found.upperBound]
            let boundaryBefore = before.map { !($0.isLetter || $0.isNumber) } ?? true
            let boundaryAfter = after.map { !($0.isLetter || $0.isNumber) } ?? true
            if boundaryBefore && boundaryAfter { return true }
            searchRange = found.upperBound..<text.endIndex
        }
        return false
    }

    /// Linear-interpolated percentile (0...100). Empty input -> 0.
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = p / 100 * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (rank - Double(lower))
    }
}

/// Per-clip scores for one config.
struct ClipScore {
    var refWords: Int
    var hypWords: Int
    var normErrors: Int
    var casedRefWords: Int
    var casedErrors: Int
    var empty: Bool
    var hallucination: Bool
    var termsExpected: Int
    var termsHit: Int

    var normWER: Double? { refWords > 0 ? Double(normErrors) / Double(refWords) : nil }
    var casedWER: Double? { casedRefWords > 0 ? Double(casedErrors) / Double(casedRefWords) : nil }

    static func score(reference: String, hypothesis: String, terms: [String]) -> ClipScore {
        let refWords = TextNormalizer.words(TextNormalizer.normalize(reference))
        let hypWords = TextNormalizer.words(TextNormalizer.normalize(hypothesis))
        let refCased = Metrics.casedWords(reference)
        let hypCased = Metrics.casedWords(hypothesis)
        let expected = terms.filter { Metrics.contains(reference, term: $0) }
        return ClipScore(
            refWords: refWords.count,
            hypWords: hypWords.count,
            normErrors: Metrics.editDistance(refWords, hypWords),
            casedRefWords: refCased.count,
            casedErrors: Metrics.editDistance(refCased, hypCased),
            empty: !refWords.isEmpty && hypothesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            // hyp > 2x ref; text produced for a silent/empty reference counts too.
            hallucination: hypWords.count > 2 * refWords.count,
            termsExpected: expected.count,
            termsHit: expected.filter { Metrics.contains(hypothesis, term: $0) }.count)
    }
}
