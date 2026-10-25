import Testing

@testable import dictate_eval

struct TextNormalizerTests {
    @Test func lowercasesAndStripsPunctuation() {
        #expect(TextNormalizer.normalize("Hello, World!") == "hello world")
        #expect(TextNormalizer.normalize("Next.js and Node.js.") == "next js and node js")
    }

    @Test func expandsContractions() {
        #expect(TextNormalizer.normalize("I can't, won't, don't.") == "i can not will not do not")
        #expect(TextNormalizer.normalize("It's what they're doing") == "it is what they are doing")
        #expect(TextNormalizer.normalize("Let's go") == "let us go")
    }

    @Test func dropsBracketsAndFillers() {
        #expect(TextNormalizer.normalize("Um, [laughs] okay (pause) uh sure") == "okay sure")
    }

    @Test func expandsTitles() {
        #expect(TextNormalizer.normalize("Dr. Smith") == "doctor smith")
        #expect(TextNormalizer.normalize("Doctor Smith") == "doctor smith")
    }

    @Test func foldsDiacriticsAndNumberFormatting() {
        #expect(TextNormalizer.normalize("Café") == "cafe")
        #expect(TextNormalizer.normalize("1,000 and 3.5 and 50%") == "1000 and 3.5 and 50%")
    }

    @Test func convertsCardinalNumberWords() {
        #expect(TextNormalizer.normalize("twenty five") == "25")
        #expect(TextNormalizer.normalize("one hundred and five") == "105")
        #expect(TextNormalizer.normalize("two thousand three hundred") == "2300")
        #expect(TextNormalizer.normalize("a hundred") == "a 100")
        #expect(TextNormalizer.normalize("call me at twenty five past three") == "call me at 25 past 3")
    }

    @Test func keepsDigitByDigitSpeechSeparate() {
        #expect(TextNormalizer.normalize("one two three") == "1 2 3")
    }

    @Test func spokenAndWrittenFormsAgree() {
        #expect(
            TextNormalizer.normalize("I bought twenty five apples, didn't I?")
                == TextNormalizer.normalize("I bought 25 apples, did not I"))
    }
}
