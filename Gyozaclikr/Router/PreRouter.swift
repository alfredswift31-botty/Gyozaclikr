import Foundation

/// A compiled, case-insensitive regular expression that can sit in a static
/// table. NSRegularExpression is immutable and thread-safe, hence unchecked.
nonisolated struct Pattern: @unchecked Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String) {
        // A bad pattern is a programming error; the tests touch every table.
        regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    func matches(_ text: String) -> Bool { first(in: text) != nil }

    func first(in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Capture group `index` of `match`, nil when the group did not take part.
    func group(_ index: Int, of match: NSTextCheckingResult, in text: String) -> String? {
        guard index < match.numberOfRanges else { return nil }
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    func text(of match: NSTextCheckingResult, in text: String) -> String {
        guard let range = Range(match.range, in: text) else { return "" }
        return String(text[range])
    }
}

/// The deterministic layer before any model: NSDataDetector over the
/// selection and the request, verb patterns for the connectors, and the
/// refusals the product makes by design (docs/research/product-and-ux.md §A
/// "Don't" and §B). Every pattern lives in one table with a comment.
nonisolated enum PreRouter {
    enum Verb: Hashable, Sendable {
        case send, remind, calendar, note, search, shortcut, define, translate, open, copyText, extract
    }

    /// Verb patterns, word-bounded, with a few synonyms each. A request can
    /// match several; the router counts the connectors among them.
    static let verbTable: [(Verb, Pattern)] = [
        // send / mail / email / forward: "send this to a@b.c", "email it to Anna".
        (.send, Pattern(#"\b(send|mail|e-?mail|forward)\b"#)),
        // remind / reminder: "remind me on Friday", "set a reminder".
        (.remind, Pattern(#"\bremind(er|ers|ed)?\b"#)),
        // calendar / event / schedule / meeting: "put this in my calendar", "schedule a meeting", "create an event".
        (.calendar, Pattern(#"\b(add|put|create|make|schedule|book|set up|save)\b[^.?!]*\b(calendar|event|meeting|appointment)\b|\b(calendar|schedule)\s+(this|it|that)\b|\b(to|in|into)\s+(my\s+)?calendar\b"#)),
        // note / save to notes: "save this to notes", "note this", "make a note".
        (.note, Pattern(#"\b(save|add|put|keep|copy)\b[^.?!]*\b(to|in|into)\s+(my\s+|apple\s+)?notes?\b|\bnote\s+(this|it|that|down)\b|\bmake\s+a\s+note\b"#)),
        // search / google / look up: "search for this", "google it", "look this up".
        (.search, Pattern(#"\b(search|google|duckduckgo|web\s+search|look\s+(this\s+|it\s+|that\s+)?up)\b"#)),
        // shortcut / run: "run my shortcut Make Tweet with this". `run` alone is not enough.
        (.shortcut, Pattern(#"\bshortcuts?\b"#)),
        // define / meaning: "define serendipity", "what does ennui mean".
        (.define, Pattern(#"\b(define|definition\s+of|meaning\s+of|what\s+does\s+\S+\s+mean)\b"#)),
        // translate: a transform with a "Translate into X" prompt.
        (.translate, Pattern(#"\btranslat(e|ed|ion)\b"#)),
        // open: only a connector when a URL is in the selection or the request.
        (.open, Pattern(#"\bopen\b"#)),
        // copy the text / OCR / read this: the words in an image, corrected only for OCR errors.
        (.copyText, Pattern(#"\b(copy|get|extract|grab)\s+(the\s+|all\s+the\s+|its\s+)?(text|words)\b|\bwhat\s+does\s+(it|this|that)\s+say\b|\bread\s+(this|it|that|the\s+(text|image|screenshot|picture))\b|\bocr\b|\btranscribe\b|\btext\s+(in|from|of)\s+(this|the|that)\s+(image|picture|screenshot|photo)\b"#)),
        // extract: list / pull out / find all <things>, or "to csv / table"; verified by quote.
        (.extract, Pattern(#"^\s*(extract|list|pull\s+out|find\s+(all|the|every)|get\s+(all|the|every)|what\s+are\s+(the|all)|which)\b|\b(to|as|into)\s+(a\s+)?(csv|table|spreadsheet|json)\b"#)),
    ]

    /// Refusals by design, matched before any engine. `imageOnly` rows fire
    /// only when the selection is an image, so "who is this from?" over a
    /// mail still reaches the model.
    static let refusalTable: [(reason: String, imageOnly: Bool, pattern: Pattern)] = [
        // "who is this person / guy / girl / man / woman / actor…", "whose face", "name this person": face identification.
        (Prompts.Refusal.person, false, Pattern(#"\bwho(se|'s|\s+is|\s+are|\s+was)?\s+(this|that|these|those|the)\s+(person|people|guy|girl|man|woman|men|women|actor|actress|celebrity|player|kid|child|baby|lady|dude|face|faces)\b|\bwhose\s+face\b|\b(name|identify|recognise|recognize)\s+(this|that|the|these)\s+(person|people|guy|girl|man|woman|face|faces|actor|actress|celebrity)\b|\bwhich\s+(actor|actress|celebrity)\b"#)),
        // Bare "who is this" over an image: the same refusal; over text it is a question for the model.
        (Prompts.Refusal.person, true, Pattern(#"\bwho\s*('s|is|are|was)\s+(this|that|these|those|he|she|they)\b"#)),
        // "where can I buy", "how much does this cost", "find this product", "shop": reverse image shopping leaves the Mac.
        (Prompts.Refusal.shopping, false, Pattern(#"\bwhere\s+(can|could|do|to|should|would)\s+(i|we|you|one)?\s*(buy|get|order|purchase)\b|\bhow\s+much\s+(does|do|is|are|would|did)\s+(this|that|it|these|those)\b|\bfind\s+(this|that|the|these)\s+(product|item)s?\b|\bshop(ping)?\b|\bbuy\s+(this|that|it|one)\b|\bprice\s+(of|for)\s+(this|that|it)\b"#)),
        // "is this true", "fact-check", "is this real / fake": world knowledge the 3B model invents.
        (Prompts.Refusal.factCheck, false, Pattern(#"\bis\s+(this|that|it)\s+(true|real|fake|legit|genuine|accurate|a\s+hoax|a\s+scam)\b|\bfact[\s-]?check\b|\btrue\s+or\s+false\b|\bverify\s+(this|that|it|these)\b"#)),
    ]

    /// A question about what an image shows, which needs an engine that can see.
    static let visualQuestion = Pattern(#"^\s*(what('s|\s+is|\s+are)(\s+in|\s+on)?\s+(this|that|it|these|those|here)\b|what\s+am\s+i\s+looking\s+at|describe\b|what\s+(kind|type|sort|breed|species)\s+of\b|what\s+(plant|animal|bird|dog|cat|flower|tree|insect|bug|building|place|landmark|dish|food|logo|car|painting)\b|identify\b|which\s+(plant|animal|bird|flower|tree|building|place|dish|painting)\b|where\s+(is|was)\s+this\b|what\s+does\s+(this|it)\s+look\s+like|caption\b|alt\s+text\b)"#)

    /// A send request that also asks for a rewrite, so the engine writes the body first.
    static let styleWords = Pattern(#"\b(formal(ly)?|casual(ly)?|polite(ly)?|friendly|professional(ly)?|shorter|short|concise|brief(ly)?|longer|rewrite|rewritten|rephrase|fix(ed)?|proofread|summar(y|ise|ize|ised|ized)|tone|style|nicer|better|clean(ed)?\s+up|tidy|simpler|plain\s+english|translat(e|ed|ion)|in\s+(german|french|spanish|italian|english|japanese|chinese|portuguese|dutch))\b"#)

    /// "send this to a@b.c" and its variants, removed to leave the style words.
    static let sendClause = Pattern(#"\b(send|mail|e-?mail|forward)\b\s*(this|it|that|the\s+selection|the\s+text|this\s+text)?\s*(to\s+)?([\w.+\-]+@[\w\-]+(\.[\w\-]+)+\s*(,|and)?\s*)+"#)

    static let email = Pattern(#"[\w.+\-]+@[\w\-]+(\.[\w\-]+)+"#)

    /// "run (my) shortcut X (with this)", "run X shortcut".
    static let shortcutName = Pattern(#"\b(run|launch|execute|start)\s+(my\s+|the\s+)?(shortcut\s+)?["“']?(.+?)["”']?(\s+shortcut)?(\s+(with|on|using|for)\s+(this|it|that|the\s+selection))?\s*[.!]?\s*$"#)

    /// "define X", "definition of X", "meaning of X", "what does X mean".
    static let definedWord = Pattern(#"\b(define|definition\s+of|meaning\s+of)\s+["“']?([\p{L}'\-]+)["”']?|\bwhat\s+does\s+["“']?([\p{L}'\-]+)["”']?\s+mean\b"#)

    /// "translate (this) to/into X".
    static let translationTarget = Pattern(#"\btranslat(e|ed|ion)\b[^.]*?\b(to|into|in)\s+([\p{L}]+(\s+[\p{L}]+)?)\s*[.!]?\s*$"#)

    /// "search (the web) (for) X" where X is not the selection.
    static let searchObject = Pattern(#"\b(search|google|look\s+up|duckduckgo)\s+(the\s+web\s+)?(for\s+)?(.+?)\s*[.!?]?\s*$"#)

    static let selectionWords = Pattern(#"^\s*(this|it|that|the\s+selection|the\s+text|the\s+selected\s+text|these|those)\s*$"#)

    static let localPrefix = Pattern(#"^\s*/local\b\s*"#)
    static let claudePrefix = Pattern(#"^\s*/claude\b\s*"#)
    static let applePrefix = Pattern(#"^\s*/apple\b\s*"#)

    /// What NSDataDetector found in a piece of text.
    struct Detected: Hashable, Sendable {
        var emails: [String] = []
        var urls: [URL] = []
        var addresses: [String] = []
        var phones: [String] = []
        var hasDate = false
    }

    static func detect(in text: String) -> Detected {
        var found = Detected()
        guard !text.isEmpty else { return found }
        let types: NSTextCheckingResult.CheckingType = [.date, .link, .address, .phoneNumber]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return found }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let matched = String(text[range])
            switch match.resultType {
            case .date: found.hasDate = true
            case .link:
                if let url = match.url {
                    if url.scheme?.lowercased() == "mailto" {
                        found.emails.append(String(url.absoluteString.dropFirst("mailto:".count)))
                    } else {
                        found.urls.append(url)
                    }
                }
            case .address: found.addresses.append(matched)
            case .phoneNumber: found.phones.append(match.phoneNumber ?? matched)
            default: break
            }
        }
        // The regex catches addresses the detector formats differently.
        for match in email.regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let range = Range(match.range, in: text) {
                let address = String(text[range])
                if !found.emails.contains(where: { $0.caseInsensitiveCompare(address) == .orderedSame }) {
                    found.emails.append(address)
                }
            }
        }
        return found
    }

    static func verbs(in text: String) -> Set<Verb> {
        Set(verbTable.filter { $0.1.matches(text) }.map(\.0))
    }

    static func refusal(in text: String, isImage: Bool) -> String? {
        for row in refusalTable where !row.imageOnly || isImage {
            if row.pattern.matches(text) { return row.reason }
        }
        return nil
    }

    static func isVisualQuestion(_ text: String) -> Bool { visualQuestion.matches(text) }

    static func wantsStyle(_ text: String) -> Bool { styleWords.matches(text) }

    static func emails(in text: String) -> [String] {
        email.regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    /// The request without its "send this to a@b.c" clause: "in formal style, keep it short".
    static func styleRest(of text: String) -> String {
        guard let match = sendClause.first(in: text), let range = Range(match.range, in: text) else { return text }
        var rest = text
        rest.removeSubrange(range)
        rest = rest.replacingOccurrences(of: #"^\s*(and|,|then|please)\s+"#, with: "", options: .regularExpression)
        rest = rest.replacingOccurrences(of: #"\s+(and|,|then|please)\s*$"#, with: "", options: .regularExpression)
        return rest.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:")))
    }

    static func shortcutName(in text: String) -> String? {
        guard let match = shortcutName.first(in: text), var name = shortcutName.group(4, of: match, in: text) else { return nil }
        name = name.replacingOccurrences(of: #"^(my|the)\s+shortcut\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        name = name.replacingOccurrences(of: #"\s+shortcut$"#, with: "", options: [.regularExpression, .caseInsensitive])
        name = name.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”'")))
        if name.isEmpty || name.lowercased() == "shortcut" || name.lowercased() == "my shortcut" { return nil }
        return name
    }

    static func definedWord(in text: String) -> String? {
        guard let match = definedWord.first(in: text) else { return nil }
        let word = definedWord.group(2, of: match, in: text) ?? definedWord.group(3, of: match, in: text)
        guard let word, !selectionWords.matches(word) else { return nil }
        return word
    }

    static func translationTarget(in text: String) -> String? {
        guard let match = translationTarget.first(in: text), let language = translationTarget.group(3, of: match, in: text) else { return nil }
        return language.capitalized
    }

    static func searchObject(in text: String) -> String? {
        guard let match = searchObject.first(in: text), let object = searchObject.group(4, of: match, in: text) else { return nil }
        let cleaned = object.replacingOccurrences(of: #"^(the\s+web\s+)?(for\s+)?"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || selectionWords.matches(cleaned) { return nil }
        return cleaned
    }

    /// Strips a leading `/local`, which forces Ollama.
    static func stripLocalPrefix(_ text: String) -> (text: String, isLocal: Bool) {
        let (rest, engine) = stripEnginePrefix(text)
        return (rest, engine == .ollama)
    }

    /// Strips a leading `/local` (Ollama), `/claude` or `/apple`: the typed way to pick an engine for one request.
    static func stripEnginePrefix(_ text: String) -> (text: String, engine: EngineKind?) {
        for (pattern, kind) in [(localPrefix, EngineKind.ollama), (claudePrefix, .claude), (applePrefix, .apple)] {
            if let match = pattern.first(in: text), let range = Range(match.range, in: text) {
                var rest = text
                rest.removeSubrange(range)
                return (rest.trimmingCharacters(in: .whitespacesAndNewlines), kind)
            }
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }
}
