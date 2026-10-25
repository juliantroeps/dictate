import Foundation

/// Approximation of Whisper's `EnglishTextNormalizer` (openai/whisper, normalizers/english.py) used to
/// score WER on content, not formatting: lowercases, drops bracketed text and fillers, expands
/// contractions, strips punctuation/diacritics, collapses cardinal number words to digits.
/// Not ported: the British -> American spelling table and ordinal/currency/"point" number forms,
/// so absolute WER can differ slightly from published Whisper numbers. Same function runs on
/// reference and hypothesis, so comparisons between configs stay valid.
enum TextNormalizer {
    private static let replacers: [(pattern: String, template: String)] = [
        (#"\bwon't\b"#, "will not"),
        (#"\bcan't\b"#, "can not"),
        (#"\blet's\b"#, "let us"),
        (#"\bain't\b"#, "aint"),
        (#"\by'all\b"#, "you all"),
        (#"\bwanna\b"#, "want to"),
        (#"\bgotta\b"#, "got to"),
        (#"\bgonna\b"#, "going to"),
        (#"\bi'ma\b"#, "i am going to"),
        (#"\bimma\b"#, "i am going to"),
        (#"\bwoulda\b"#, "would have"),
        (#"\bcoulda\b"#, "could have"),
        (#"\bshoulda\b"#, "should have"),
        (#"\bma'am\b"#, "madam"),
        (#"\bmr\b"#, "mister "),
        (#"\bmrs\b"#, "missus "),
        (#"\bst\b"#, "saint "),
        (#"\bdr\b"#, "doctor "),
        (#"\bprof\b"#, "professor "),
        (#"\bcapt\b"#, "captain "),
        (#"\bgov\b"#, "governor "),
        (#"\bald\b"#, "alderman "),
        (#"\bgen\b"#, "general "),
        (#"\bsen\b"#, "senator "),
        (#"\brep\b"#, "representative "),
        (#"\bpres\b"#, "president "),
        (#"\brev\b"#, "reverend "),
        (#"\bhon\b"#, "honorable "),
        (#"\basst\b"#, "assistant "),
        (#"\bassoc\b"#, "associate "),
        (#"\blt\b"#, "lieutenant "),
        (#"\bcol\b"#, "colonel "),
        (#"\bjr\b"#, "junior "),
        (#"\bsr\b"#, "senior "),
        (#"\besq\b"#, "esquire "),
        (#"'d been\b"#, " had been"),
        (#"'s been\b"#, " has been"),
        (#"'d gone\b"#, " had gone"),
        (#"'s gone\b"#, " has gone"),
        (#"'d done\b"#, " had done"),
        (#"'s got\b"#, " has got"),
        (#"n't\b"#, " not"),
        (#"'re\b"#, " are"),
        (#"'s\b"#, " is"),
        (#"'d\b"#, " would"),
        (#"'ll\b"#, " will"),
        (#"'t\b"#, " not"),
        (#"'ve\b"#, " have"),
        (#"'m\b"#, " am"),
    ]

    private static let keptSymbols: Set<Unicode.Scalar> = [".", "%", "$", "\u{A2}", "\u{20AC}", "\u{A3}"]

    static func normalize(_ input: String) -> String {
        var s = input.lowercased()
        s = sub(#"[<\[][^>\]]*[>\]]"#, "", s)
        s = sub(#"\(([^)]+?)\)"#, "", s)
        s = sub(#"\b(hmm|mm|mhm|mmm|uh|um)\b"#, "", s)
        s = sub(#"\s+'"#, "'", s)
        for (pattern, template) in replacers {
            s = sub(pattern, template, s)
        }
        s = sub(#"(\d),(\d)"#, "$1$2", s)
        s = sub(#"\.([^0-9]|$)"#, " $1", s)
        s = removeSymbolsAndDiacritics(s)
        s = normalizeNumbers(s)
        s = sub(#"[.$¢€£]([^0-9])"#, " $1", s)
        s = sub(#"([^0-9])%"#, "$1 ", s)
        s = sub(#"\s+"#, " ", s)
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func words(_ normalized: String) -> [String] {
        normalized.split(separator: " ").map(String.init)
    }

    private static func sub(_ pattern: String, _ template: String, _ s: String) -> String {
        s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }

    /// NFKD, drop combining marks, turn other marks/symbols/punctuation into spaces (keeping `.%$¢€£`).
    private static func removeSymbolsAndDiacritics(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.decomposedStringWithCompatibilityMapping.unicodeScalars {
            if keptSymbols.contains(scalar) {
                out.append(scalar)
                continue
            }
            switch scalar.properties.generalCategory {
            case .nonspacingMark:
                continue
            case .spacingMark, .enclosingMark, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol,
                .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                .initialPunctuation, .finalPunctuation, .otherPunctuation:
                out.append(" ")
            default:
                out.append(scalar)
            }
        }
        return String(out)
    }

    // MARK: Cardinal numbers ("twenty five" -> "25")

    private static let smallNumbers: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80,
        "ninety": 90,
    ]
    private static let scales: [String: Int] = [
        "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000,
    ]

    private static func isNumberWord(_ w: String) -> Bool {
        smallNumbers[w] != nil || tens[w] != nil || scales[w] != nil || w == "hundred"
    }

    /// Greedy left-to-right: a run of number words becomes one number; a word that cannot extend the
    /// current number (e.g. "one two three") starts the next one, so digit-by-digit speech stays separate.
    private static func normalizeNumbers(_ s: String) -> String {
        let tokens = s.split(separator: " ").map(String.init)
        var out: [String] = []
        var total = 0
        var current = 0
        var inNumber = false
        var lastWasTens = false
        var lastWasUnitOrTeen = false

        func flush() {
            if inNumber { out.append(String(total + current)) }
            total = 0
            current = 0
            inNumber = false
            lastWasTens = false
            lastWasUnitOrTeen = false
        }

        var index = 0
        while index < tokens.count {
            let word = tokens[index]
            if word == "and", inNumber, !lastWasTens, index + 1 < tokens.count,
                smallNumbers[tokens[index + 1]] != nil || tens[tokens[index + 1]] != nil, current >= 100 || total > 0
            {
                index += 1  // "one hundred and five"
                continue
            }
            guard isNumberWord(word) else {
                flush()
                out.append(word)
                index += 1
                continue
            }
            if let small = smallNumbers[word] {
                let canExtend = inNumber && !lastWasUnitOrTeen && !lastWasTens && current % 100 == 0
                let canFillTens = inNumber && lastWasTens && small < 10 && small > 0
                if inNumber && !canExtend && !canFillTens { flush() }
                current += small
                lastWasUnitOrTeen = true
                lastWasTens = false
            } else if let ten = tens[word] {
                if inNumber && (lastWasTens || lastWasUnitOrTeen || current % 100 != 0) { flush() }
                current += ten
                lastWasTens = true
                lastWasUnitOrTeen = false
            } else if word == "hundred" {
                current = max(current, 1) * 100
                lastWasTens = false
                lastWasUnitOrTeen = false
            } else if let scale = scales[word] {
                total += max(current, 1) * scale
                current = 0
                lastWasTens = false
                lastWasUnitOrTeen = false
            }
            inNumber = true
            index += 1
        }
        flush()
        return out.joined(separator: " ")
    }
}
