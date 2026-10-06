import Foundation

/// Decides what to do with a request: a chip's fixed prompt, a connector the
/// app can perform without the model, an extraction, an image question, or
/// free text for the engine. Pure and deterministic: the same request and
/// engine table always give the same Route, so the tests are a table
/// (docs/research/product-and-ux.md §B). The order is: refusals, single
/// connectors, images, extraction, compound requests, then the model.
nonisolated struct Router: Routing {
    /// The clock, injectable so "Friday" is testable.
    let now: @Sendable () -> Date
    let calendar: Calendar

    init(now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .autoupdatingCurrent) {
        self.now = now
        self.calendar = calendar
    }

    static let noEngine = "No engine is available."
    static let noImageEngine = "Neither engine can see images on this Mac. Ollama with a vision model, or macOS 27, is needed."
    static let ocrPrompt = "Return the text exactly as it appears, corrected for OCR errors only."
    static let explainPrompt = "Explain what this says in two or three sentences, using only the selected text."
    static let whichShortcut = "Which Shortcut? Say “run shortcut Name”."

    func route(_ request: Request, engines: [EngineKind: Set<EngineCapability>]) -> Route {
        let (text, typed) = PreRouter.stripEnginePrefix(request.text)
        let forced = typed ?? request.engine
        let engine = forced ?? Self.defaultEngine(engines)
        let selection = request.selection
        let content = (selection.text ?? selection.word ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let dates = DateParsing(now: now(), calendar: calendar)

        if let chip = request.chip {
            return routeChip(chip, content: content, engine: engine, dates: dates)
        }

        // 1. Refused by design, before any engine.
        if let reason = PreRouter.refusal(in: text, isImage: selection.kind == .image) {
            return .refuse(reason: reason)
        }

        // 2. Single connectors: the payload is the selection, no model needed.
        let verbs = PreRouter.verbs(in: text)
        let inRequest = PreRouter.detect(in: text)
        let inSelection = PreRouter.detect(in: content)
        let urls = inRequest.urls + inSelection.urls
        var connectors = verbs.intersection([.send, .remind, .calendar, .note, .search, .shortcut])
        if verbs.contains(.open), !urls.isEmpty { connectors.insert(.open) }
        if connectors.count > 1 { return .agent(engine: .apple) }

        if let connector = connectors.first {
            switch connector {
            case .send:
                let recipients = inRequest.emails
                guard !recipients.isEmpty, !content.isEmpty else { return .agent(engine: .apple) }
                if PreRouter.wantsStyle(text) {
                    guard let engine else { return .refuse(reason: Self.noEngine) }
                    let rest = PreRouter.styleRest(of: text)
                    let prompt = rest.isEmpty ? "Rewrite this as a message. Reply with the message body only."
                        : "Rewrite this \(rest). Reply with the message body only."
                    return .composeThen(prompt: prompt, engine: engine, status: "Drafting…", proposal: .mail(to: recipients, subject: nil))
                }
                return .perform(.sendMail(to: recipients, subject: SelectionText.title(content), body: content))

            case .remind:
                let found = dates.firstDate(in: text) ?? dates.firstDate(in: content)
                let title = Self.title(content: content, request: text, verbClause: #"^\s*(please\s+)?(set\s+a\s+reminder|remind\s+me|reminder)\s*(?:(to|about|of|for|that)\b)?\s*(?:(this|it|that)\b)?\s*"#, dropping: found?.text)
                guard !title.isEmpty else { return .agent(engine: .apple) }
                // A range ("next week") is not a due date: the card asks when.
                let due = found?.precision == .week ? nil : found?.date
                return .perform(.createReminder(title: title, due: due, dueText: found?.text))

            case .calendar:
                let found = dates.firstDate(in: text) ?? dates.firstDate(in: content)
                let title = Self.title(content: content, request: text, verbClause: #"^\s*(please\s+)?(add|put|create|make|schedule|book|set\s+up|save)\s+(?:(this|it|that|an?\s+(event|meeting|appointment))\b)?\s*(?:(to|in|into|on|for)\b)?\s*(my\s+)?(calendar\b)?\s*"#, dropping: found?.text)
                guard !title.isEmpty else { return .agent(engine: .apple) }
                let start = found?.precision == .week ? nil : found?.date
                let end = start.map { $0.addingTimeInterval(3600) }
                let location = inSelection.addresses.first
                return .perform(.createEvent(title: title, start: start, end: end, location: location, whenText: found?.text))

            case .note:
                guard !content.isEmpty else { return .agent(engine: .apple) }
                return .perform(.saveNote(title: SelectionText.title(content), body: content))

            case .search:
                if let object = PreRouter.searchObject(in: text) {
                    return .perform(.search(query: SelectionText.collapsed(object, limit: 200)))
                }
                guard !content.isEmpty else { return .refuse(reason: "Nothing to search for.") }
                return .perform(.search(query: SelectionText.collapsed(content, limit: 200)))

            case .shortcut:
                guard let name = PreRouter.shortcutName(in: text) else { return .refuse(reason: Self.whichShortcut) }
                return .perform(.runShortcut(name: name, input: content))

            case .open:
                return .perform(.openURL(urls[0]))

            default:
                break
            }
        }

        // 3. Define: the system dictionary, no model.
        if let word = PreRouter.definedWord(in: text) {
            return .define(word: word)
        }
        if verbs.contains(.define), let word = Self.singleWord(selection) {
            return .define(word: word)
        }
        if text.isEmpty, selection.kind == .word, let word = Self.singleWord(selection) {
            return .define(word: word)
        }

        // 4. Translate: a transform with a fixed prompt.
        if verbs.contains(.translate) {
            guard let engine else { return .refuse(reason: Self.noEngine) }
            let language = PreRouter.translationTarget(in: text) ?? "English"
            return .transform(prompt: "Translate into \(language). Keep the meaning and the formatting; reply with the translation only.",
                              engine: engine, status: "Translating…")
        }

        // 5. Images: the words in it, or a question about what it shows.
        if selection.kind == .image {
            if verbs.contains(.copyText) {
                guard let engine else { return .refuse(reason: Self.noEngine) }
                return .transform(prompt: Self.ocrPrompt, engine: engine, status: "Reading…")
            }
            if text.isEmpty || content.isEmpty || PreRouter.isVisualQuestion(text) {
                guard let seeing = Self.imageEngine(preferring: forced, engines) else {
                    return .refuse(reason: Self.noImageEngine)
                }
                return .describeImage(question: text, engine: seeing)
            }
            // Otherwise the OCR text is the selection and the request falls through.
        }

        // 6. Extraction, verified by quote.
        if verbs.contains(.extract) {
            guard let engine else { return .refuse(reason: Self.noEngine) }
            return .extract(prompt: text, engine: engine)
        }

        // 7. Everything else is a transform of the selection.
        guard let engine else { return .refuse(reason: Self.noEngine) }
        if text.isEmpty {
            return .transform(prompt: Self.explainPrompt, engine: engine, status: "Reading…")
        }
        return .transform(prompt: text, engine: engine, status: "Working…")
    }

    // MARK: Chips

    private func routeChip(_ chip: Chip, content: String, engine: EngineKind?, dates: DateParsing) -> Route {
        if chip == .remind, let found = dates.firstDate(in: content), found.precision != .week {
            return .perform(.createReminder(title: SelectionText.title(content, dropping: found.text), due: found.date, dueText: found.text))
        }
        guard let engine else { return .refuse(reason: Self.noEngine) }
        if chip == .remind {
            return .composeThen(prompt: Prompts.prompt(for: .remind), engine: engine, status: chip.statusVerb, proposal: .reminder(dueText: nil))
        }
        return .transform(prompt: Prompts.prompt(for: chip), engine: engine, status: chip.statusVerb)
    }

    // MARK: Engines

    /// Apple when present, else Ollama, else nothing.
    static func defaultEngine(_ engines: [EngineKind: Set<EngineCapability>]) -> EngineKind? {
        if engines[.apple] != nil { return .apple }
        if engines[.ollama] != nil { return .ollama }
        if engines[.claude] != nil { return .claude }
        return nil
    }

    /// An engine that can see: the preferred one if it can, else Apple, else Ollama.
    static func imageEngine(preferring preferred: EngineKind?, _ engines: [EngineKind: Set<EngineCapability>]) -> EngineKind? {
        if let preferred, engines[preferred]?.contains(.image) == true { return preferred }
        for kind in [EngineKind.apple, .ollama, .claude] where engines[kind]?.contains(.image) == true { return kind }
        return nil
    }

    // MARK: Titles

    /// A reminder or event title: the selection's first line, or the request
    /// without its verb and date when nothing is selected.
    private static func title(content: String, request: String, verbClause: String, dropping fragment: String?) -> String {
        if !content.isEmpty { return SelectionText.title(content, dropping: fragment) }
        var rest = request.replacingOccurrences(of: verbClause, with: "", options: [.regularExpression, .caseInsensitive])
        if let fragment { rest = SelectionText.removing(fragment, from: rest) }
        return SelectionText.title(rest)
    }

    private static func singleWord(_ selection: Selection) -> String? {
        if let word = selection.word, !word.isEmpty { return word }
        guard let text = selection.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, text.count <= 40 else { return nil }
        return text.trimmingCharacters(in: .punctuationCharacters)
    }
}

/// Text helpers shared by the routes: titles and trimmed queries.
nonisolated enum SelectionText {
    /// The first non-blank line, without `fragment`, tidied and cut to `limit` characters.
    static func title(_ text: String, dropping fragment: String? = nil, limit: Int = 60) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        var title = line
        if let fragment { title = removing(fragment, from: title) }
        title = tidy(title)
        if title.count > limit {
            title = String(title.prefix(limit))
            title = tidy(title)
        }
        return title
    }

    /// `text` without the first occurrence of `fragment` (case-insensitive), tidied.
    static func removing(_ fragment: String, from text: String) -> String {
        guard !fragment.isEmpty, let range = text.range(of: fragment, options: [.caseInsensitive]) else { return tidy(text) }
        var rest = text
        rest.removeSubrange(range)
        return tidy(rest)
    }

    /// Whitespace collapsed to single spaces and cut to `limit` characters.
    static func collapsed(_ text: String, limit: Int) -> String {
        let joined = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(joined.prefix(limit)).trimmingCharacters(in: .whitespaces)
    }

    /// Collapses whitespace, mends " ," and strips dangling punctuation.
    private static func tidy(_ text: String) -> String {
        var tidy = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        tidy = tidy.replacingOccurrences(of: " ,", with: ",").replacingOccurrences(of: " ;", with: ";")
        tidy = tidy.replacingOccurrences(of: ",,", with: ",")
        return tidy.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;:-–—")))
    }
}
