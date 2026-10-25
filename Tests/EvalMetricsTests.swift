import Foundation
import Testing

@testable import dictate_eval

struct EvalMetricsTests {
    @Test func editDistanceCountsSubstitutionsDeletionsInsertions() {
        #expect(Metrics.editDistance(["a", "b", "c"], ["a", "b", "c"]) == 0)
        #expect(Metrics.editDistance(["a", "b", "c"], ["a", "x", "c"]) == 1)
        #expect(Metrics.editDistance(["a", "b", "c"], ["a", "c"]) == 1)
        #expect(Metrics.editDistance(["a", "c"], ["a", "b", "c"]) == 1)
        #expect(Metrics.editDistance(["a", "b"], []) == 2)
        #expect(Metrics.editDistance([], ["a", "b"]) == 2)
    }

    @Test func casedWordsTrimPunctuationButKeepCaseAndInnerDots() {
        #expect(Metrics.casedWords("Use Next.js, then \"Supabase\".") == ["Use", "Next.js", "then", "Supabase"])
    }

    @Test func termMatchIsCaseSensitiveAndRespectsWordBoundaries() {
        #expect(Metrics.contains("I use Next.js daily.", term: "Next.js"))
        #expect(!Metrics.contains("I use next.js daily.", term: "Next.js"))
        #expect(!Metrics.contains("I use Google daily.", term: "Go"))
        #expect(Metrics.contains("Google and Go.", term: "Go"))
        #expect(Metrics.contains("pnpm", term: "pnpm"))
    }

    @Test func percentileInterpolates() {
        #expect(Metrics.percentile([], 50) == 0)
        #expect(Metrics.percentile([4], 95) == 4)
        #expect(Metrics.percentile([1, 2, 3, 4, 5], 50) == 3)
        #expect(abs(Metrics.percentile([1, 2, 3, 4], 95) - 3.85) < 1e-9)
    }

    @Test func scoreFlagsEmptyAndHallucination() {
        let empty = ClipScore.score(reference: "Yes, thanks.", hypothesis: "", terms: [])
        #expect(empty.empty)
        #expect(empty.normErrors == 2)
        #expect(empty.normWER == 1)

        let hallucinated = ClipScore.score(reference: "Yes.", hypothesis: "Thanks for watching this video", terms: [])
        #expect(hallucinated.hallucination)
        #expect(!hallucinated.empty)

        let silentRef = ClipScore.score(reference: "", hypothesis: "Thank you.", terms: [])
        #expect(silentRef.hallucination)
        #expect(silentRef.normWER == nil)
    }

    @Test func scoreCountsCasedErrorsAndTerms() {
        let score = ClipScore.score(
            reference: "I use Next.js and Supabase.", hypothesis: "I use next.js and Superbase.",
            terms: ["Next.js", "Supabase", "pnpm"])
        #expect(score.normErrors == 1)
        #expect(score.casedErrors == 2)
        #expect(score.termsExpected == 2)
        #expect(score.termsHit == 0)
    }

    @Test func csvEscapesCommasQuotesAndNewlines() {
        #expect(Report.csvEscape("plain") == "plain")
        #expect(Report.csvEscape("a,b") == "\"a,b\"")
        #expect(Report.csvEscape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(Report.csvEscape("a\nb") == "\"a\nb\"")
    }
}
