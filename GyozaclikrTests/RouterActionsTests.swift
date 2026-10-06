import AppKit
import Contacts
import EventKit
import Foundation
import Testing
@testable import Gyozaclikr

// MARK: - Fixtures

/// A fixed clock: Tuesday 6 October 2026, 10:00 UTC, weeks starting Monday.
nonisolated enum Fixed {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static let now = date(2026, 10, 6, 10, 0)
    static let router = Router(now: { now }, calendar: calendar)
    static let parser = DateParsing(now: now, calendar: calendar)

    /// Apple text-only (macOS 26), Ollama with a vision model.
    static let both: [EngineKind: Set<EngineCapability>] = [.apple: [.text, .structured, .tools], .ollama: [.text, .image]]
    /// Apple with image input (macOS 27), Ollama text-only.
    static let appleSees: [EngineKind: Set<EngineCapability>] = [.apple: [.text, .image, .structured, .tools], .ollama: [.text]]
    static let blind: [EngineKind: Set<EngineCapability>] = [.apple: [.text], .ollama: [.text]]
    static let ollamaOnly: [EngineKind: Set<EngineCapability>] = [.ollama: [.text, .image]]
    static let none: [EngineKind: Set<EngineCapability>] = [:]

    static func text(_ text: String) -> Selection { Selection(kind: .text, text: text, isEditable: true) }
    static func word(_ word: String) -> Selection { Selection(kind: .word, word: word) }
    static func image(ocr: String?) -> Selection {
        Selection(kind: .image, text: ocr, image: ImagePayload(png: Data(), pointSize: CGSize(width: 320, height: 200), scale: 2),
                  ocrWordCount: ocr.map { $0.split(separator: " ").count })
    }

    static let releaseNotes = """
        Version 3.0 drops support for macOS 13.
        The `--legacy` flag is removed; use `--compat` instead.
        Performance improved by 20% on Apple silicon.
        """
    static let complaint = "Order 4471 arrived two weeks late and the box was crushed. I want a refund or a replacement, and I'd like to know what went wrong."
    static let longWords = String(repeating: "word ", count: 60).trimmingCharacters(in: .whitespaces)
    static let longQuery = String(repeating: "word ", count: 40).trimmingCharacters(in: .whitespaces)
}

/// One row of the routing table: a request over a selection and the Route it must give.
struct RouteCase: Sendable, CustomTestStringConvertible {
    let name: String
    let request: Request
    let engines: [EngineKind: Set<EngineCapability>]
    let expected: Route

    init(_ name: String, _ selection: Selection, _ text: String = "", chip: Chip? = nil, engine: EngineKind? = nil,
         engines: [EngineKind: Set<EngineCapability>] = Fixed.both, _ expected: Route) {
        self.name = name
        request = Request(selection: selection, text: text, chip: chip, engine: engine)
        self.engines = engines
        self.expected = expected
    }

    var testDescription: String { name }
}

nonisolated enum RouteCases {
    static let all: [RouteCase] = [
        // The eight transcripts from docs/research/product-and-ux.md §B (3 is checked separately: its location depends on NSDataDetector).
        RouteCase("T1 chip Formal", Fixed.text("hey can u send me the report by tmrw thx"), chip: .formal,
                  .transform(prompt: Prompts.prompt(for: .formal), engine: .apple, status: "Rewriting…")),
        RouteCase("T2 list the breaking changes", Fixed.text(Fixed.releaseNotes), "list the breaking changes",
                  .extract(prompt: "list the breaking changes", engine: .apple)),
        RouteCase("T4 send in formal style", Fixed.text(Fixed.complaint), "send this to anna@example.com in formal style, keep it short",
                  .composeThen(prompt: "Rewrite this in formal style, keep it short. Reply with the message body only.", engine: .apple,
                               status: "Drafting…", proposal: .mail(to: ["anna@example.com"], subject: nil))),
        RouteCase("T5 explain a terminal error", Fixed.image(ocr: "zsh: command not found: brew"), "explain this",
                  .transform(prompt: "explain this", engine: .apple, status: "Working…")),
        RouteCase("T6 what is this plant (Apple sees)", Fixed.image(ocr: nil), "what is this", engines: Fixed.appleSees,
                  .describeImage(question: "what is this", engine: .apple)),
        RouteCase("T6 what is this plant (only Ollama sees)", Fixed.image(ocr: nil), "what is this",
                  .describeImage(question: "what is this", engine: .ollama)),
        RouteCase("T6 what is this plant (nobody sees)", Fixed.image(ocr: nil), "what is this", engines: Fixed.blind,
                  .refuse(reason: Router.noImageEngine)),
        RouteCase("T7 remind me, next week", Fixed.text("Lunch with Sam next week"), "remind me",
                  .perform(.createReminder(title: "Lunch with Sam", due: nil, dueText: "next week"))),
        RouteCase("T8 who is this", Fixed.image(ocr: nil), "who is this", .refuse(reason: Prompts.Refusal.person)),

        // Refusals by design.
        RouteCase("who is this person (text)", Fixed.text("A tall man in a grey coat."), "who is this person", .refuse(reason: Prompts.Refusal.person)),
        RouteCase("whose face is this", Fixed.image(ocr: nil), "whose face is this", .refuse(reason: Prompts.Refusal.person)),
        RouteCase("name this actor", Fixed.image(ocr: nil), "name this actor", .refuse(reason: Prompts.Refusal.person)),
        RouteCase("where can I buy this", Fixed.image(ocr: "ACME"), "where can I buy this", .refuse(reason: Prompts.Refusal.shopping)),
        RouteCase("how much does this cost", Fixed.image(ocr: nil), "how much does this cost", .refuse(reason: Prompts.Refusal.shopping)),
        RouteCase("find this product", Fixed.image(ocr: nil), "find this product", .refuse(reason: Prompts.Refusal.shopping)),
        RouteCase("is this true", Fixed.text("The moon is made of cheese."), "is this true", .refuse(reason: Prompts.Refusal.factCheck)),
        RouteCase("fact-check this", Fixed.text("The moon is made of cheese."), "fact-check this", .refuse(reason: Prompts.Refusal.factCheck)),
        RouteCase("is this real", Fixed.image(ocr: nil), "is this real or fake?", .refuse(reason: Prompts.Refusal.factCheck)),
        RouteCase("who is this from (text, not refused)", Fixed.text("Hi, re: the invoice…"), "who is this from?",
                  .transform(prompt: "who is this from?", engine: .apple, status: "Working…")),

        // /local and engine choice.
        RouteCase("/local forces Ollama", Fixed.text(Fixed.complaint), "/local summarise the risks",
                  .transform(prompt: "summarise the risks", engine: .ollama, status: "Working…")),
        RouteCase("/local image question", Fixed.image(ocr: nil), "/local what is this",
                  .describeImage(question: "what is this", engine: .ollama)),
        RouteCase("/claude forces Claude", Fixed.text(Fixed.complaint), "/claude summarise the risks",
                  .transform(prompt: "summarise the risks", engine: .claude, status: "Working…")),
        RouteCase("/apple wins over the box's engine", Fixed.text("x"), "/apple make it rhyme", engine: .claude,
                  .transform(prompt: "make it rhyme", engine: .apple, status: "Working…")),
        RouteCase("the box's engine is the request's", Fixed.text("x"), "make it rhyme", engine: .claude,
                  .transform(prompt: "make it rhyme", engine: .claude, status: "Working…")),
        RouteCase("/local wins over the box's engine", Fixed.text("x"), "/local make it rhyme", engine: .apple,
                  .transform(prompt: "make it rhyme", engine: .apple, status: "Working…")),
        RouteCase("Ollama when Apple is absent", Fixed.text("x"), "make it rhyme", engines: Fixed.ollamaOnly,
                  .transform(prompt: "make it rhyme", engine: .ollama, status: "Working…")),
        RouteCase("no engine at all", Fixed.text("x"), "make it rhyme", engines: Fixed.none, .refuse(reason: Router.noEngine)),
        RouteCase("a connector needs no engine", Fixed.text("quantum entanglement"), "search for this", engines: Fixed.none,
                  .perform(.search(query: "quantum entanglement"))),

        // Chips.
        RouteCase("chip Fix", Fixed.text("teh cat"), chip: .fix, .transform(prompt: Prompts.prompt(for: .fix), engine: .apple, status: "Rewriting…")),
        RouteCase("chip Shorter", Fixed.text(Fixed.complaint), chip: .shorter, .transform(prompt: Prompts.prompt(for: .shorter), engine: .apple, status: "Rewriting…")),
        RouteCase("chip Casual", Fixed.text(Fixed.complaint), chip: .casual, .transform(prompt: Prompts.prompt(for: .casual), engine: .apple, status: "Rewriting…")),
        RouteCase("chip Summarise", Fixed.text(Fixed.releaseNotes), chip: .summarise, .transform(prompt: Prompts.prompt(for: .summarise), engine: .apple, status: "Summarising…")),
        RouteCase("chip List", Fixed.text(Fixed.releaseNotes), chip: .list, .transform(prompt: Prompts.prompt(for: .list), engine: .apple, status: "Listing…")),
        RouteCase("chip Reply", Fixed.text("Can you make Thursday?"), chip: .reply, .transform(prompt: Prompts.prompt(for: .reply), engine: .apple, status: "Drafting…")),
        RouteCase("chip Remind with a date", Fixed.text("Pay the electricity bill by Friday"), chip: .remind,
                  .perform(.createReminder(title: "Pay the electricity bill", due: Fixed.date(2026, 10, 9, 9, 0), dueText: "by Friday"))),
        RouteCase("chip Remind without a date", Fixed.text("Call the plumber"), chip: .remind,
                  .composeThen(prompt: Prompts.prompt(for: .remind), engine: .apple, status: "Reading…", proposal: .reminder(dueText: nil))),
        RouteCase("chip Fix with no engine", Fixed.text("teh cat"), chip: .fix, engines: Fixed.none, .refuse(reason: Router.noEngine)),
        RouteCase("chip Fix on Ollama only", Fixed.text("teh cat"), chip: .fix, engines: Fixed.ollamaOnly,
                  .transform(prompt: Prompts.prompt(for: .fix), engine: .ollama, status: "Rewriting…")),

        // Single connectors without the model.
        RouteCase("send this to an address", Fixed.text("Minutes\nWe agreed to ship on Friday."), "send this to a@b.c",
                  .perform(.sendMail(to: ["a@b.c"], subject: "Minutes", body: "Minutes\nWe agreed to ship on Friday."))),
        RouteCase("email politely composes first", Fixed.text(Fixed.complaint), "email this to bob@example.org politely",
                  .composeThen(prompt: "Rewrite this politely. Reply with the message body only.", engine: .apple, status: "Drafting…",
                               proposal: .mail(to: ["bob@example.org"], subject: nil))),
        RouteCase("send to a name needs the agent", Fixed.text(Fixed.complaint), "send this to Anna", .agent(engine: .apple)),
        RouteCase("remind me on Friday", Fixed.text("Pay the invoice"), "remind me about this on Friday",
                  .perform(.createReminder(title: "Pay the invoice", due: Fixed.date(2026, 10, 9, 9, 0), dueText: "on Friday"))),
        RouteCase("remind me tomorrow 3pm", Fixed.text("Call mum"), "remind me tomorrow 3pm",
                  .perform(.createReminder(title: "Call mum", due: Fixed.date(2026, 10, 7, 15, 0), dueText: "tomorrow 3pm"))),
        RouteCase("remind me with no selection", Selection.none, "remind me to water the plants in 2 hours",
                  .perform(.createReminder(title: "water the plants", due: Fixed.date(2026, 10, 6, 12, 0), dueText: "in 2 hours"))),
        RouteCase("remind me with no date", Fixed.text("Renew the passport"), "remind me about this",
                  .perform(.createReminder(title: "Renew the passport", due: nil, dueText: nil))),
        RouteCase("add to calendar tomorrow 3pm", Fixed.text("Team sync"), "add this to my calendar tomorrow 3pm",
                  .perform(.createEvent(title: "Team sync", start: Fixed.date(2026, 10, 7, 15, 0), end: Fixed.date(2026, 10, 7, 16, 0),
                                        location: nil, whenText: "tomorrow 3pm"))),
        RouteCase("save to notes", Fixed.text("Shopping\nmilk, eggs"), "save this to notes",
                  .perform(.saveNote(title: "Shopping", body: "Shopping\nmilk, eggs"))),
        RouteCase("search for this", Fixed.text("quantum entanglement explained"), "search for this",
                  .perform(.search(query: "quantum entanglement explained"))),
        RouteCase("google this, trimmed to 200", Fixed.text(Fixed.longWords), "google this", .perform(.search(query: Fixed.longQuery))),
        RouteCase("google a phrase", Fixed.text("unrelated"), "google quantum entanglement", .perform(.search(query: "quantum entanglement"))),
        RouteCase("open a selected URL", Fixed.text("https://example.com/docs"), "open",
                  .perform(.openURL(URL(string: "https://example.com/docs")!))),
        RouteCase("open the link in a sentence", Fixed.text("See https://example.com/a for details"), "open the link",
                  .perform(.openURL(URL(string: "https://example.com/a")!))),
        RouteCase("run my shortcut", Fixed.text("Hello"), "run my shortcut Make Tweet with this",
                  .perform(.runShortcut(name: "Make Tweet", input: "Hello"))),
        RouteCase("run X shortcut", Fixed.text("Hello"), "run Make Tweet shortcut", .perform(.runShortcut(name: "Make Tweet", input: "Hello"))),
        RouteCase("run shortcut without a name", Fixed.text("Hello"), "run shortcut", .refuse(reason: Router.whichShortcut)),
        RouteCase("define a word", Fixed.text("unrelated"), "define serendipity", .define(word: "serendipity")),
        RouteCase("what does X mean", Fixed.text("unrelated"), "what does ennui mean", .define(word: "ennui")),
        RouteCase("empty request on the word under the pointer", Fixed.word("petrichor"), "", .define(word: "petrichor")),
        RouteCase("translate into German", Fixed.text("Good morning"), "translate this into German",
                  .transform(prompt: "Translate into German. Keep the meaning and the formatting; reply with the translation only.",
                             engine: .apple, status: "Translating…")),

        // Images.
        RouteCase("copy the text out of an image", Fixed.image(ocr: "Hello world"), "copy the text",
                  .transform(prompt: Router.ocrPrompt, engine: .apple, status: "Reading…")),
        RouteCase("what does it say", Fixed.image(ocr: "Hello world"), "what does it say",
                  .transform(prompt: Router.ocrPrompt, engine: .apple, status: "Reading…")),
        RouteCase("empty request on an image", Fixed.image(ocr: nil), "", .describeImage(question: "", engine: .ollama)),
        RouteCase("describe an image that has text", Fixed.image(ocr: "Total 42.00"), "describe this image",
                  .describeImage(question: "describe this image", engine: .ollama)),
        RouteCase("extract from a screenshot", Fixed.image(ocr: "Rent 1200\nPower 80"), "extract the amounts",
                  .extract(prompt: "extract the amounts", engine: .apple)),

        // Extraction, compound requests, free text.
        RouteCase("extract all the dates", Fixed.text(Fixed.releaseNotes), "extract all the dates", .extract(prompt: "extract all the dates", engine: .apple)),
        RouteCase("pull out the action items", Fixed.text(Fixed.releaseNotes), "pull out the action items", .extract(prompt: "pull out the action items", engine: .apple)),
        RouteCase("into a table", Fixed.text(Fixed.releaseNotes), "turn this into a table", .extract(prompt: "turn this into a table", engine: .apple)),
        RouteCase("two connectors go to the agent", Fixed.text("Lunch Friday"), "remind me and email it to a@b.c", .agent(engine: .apple)),
        RouteCase("calendar and reminder go to the agent", Fixed.text("Dentist Thursday 3pm"), "put this in my calendar and remind me the day before",
                  .agent(engine: .apple)),
        RouteCase("free text is a transform", Fixed.text(Fixed.complaint), "make it sound happier",
                  .transform(prompt: "make it sound happier", engine: .apple, status: "Working…")),
        RouteCase("empty request on text explains it", Fixed.text(Fixed.complaint), "", .transform(prompt: Router.explainPrompt, engine: .apple, status: "Reading…")),
    ]
}

// MARK: - Router

struct RouterTests {
    @Test(arguments: RouteCases.all)
    func routes(_ row: RouteCase) {
        #expect(Fixed.router.route(row.request, engines: row.engines) == row.expected)
    }

    /// Transcript 3: the date comes from the selection, the title drops it,
    /// the event lasts an hour. The location is whatever NSDataDetector makes
    /// of "Hauptstrasse 12", which is recorded rather than asserted.
    @Test func transcript3PutsTheDentistInTheCalendar() throws {
        let route = Fixed.router.route(Request(selection: Fixed.text("Dentist Thursday 3pm, Hauptstrasse 12"), text: "put this in my calendar"), engines: Fixed.both)
        guard case .perform(.createEvent(let title, let start, let end, let location, let whenText)) = route else {
            Issue.record("Expected createEvent, got \(route)")
            return
        }
        #expect(title == "Dentist, Hauptstrasse 12")
        #expect(start == Fixed.date(2026, 10, 8, 15, 0))
        #expect(end == Fixed.date(2026, 10, 8, 16, 0))
        #expect(whenText == "Thursday 3pm")
        Measurements.record(["transcript 3 location from NSDataDetector: \(location ?? "nil")"], in: "router.txt")
    }

    @Test func routingIsDeterministic() {
        let request = Request(selection: Fixed.text(Fixed.complaint), text: "send this to anna@example.com in formal style")
        let first = Fixed.router.route(request, engines: Fixed.both)
        for _ in 0..<5 { #expect(Fixed.router.route(request, engines: Fixed.both) == first) }
    }

    @Test func everyPatternCompilesAndTheTablesAreComplete() {
        #expect(PreRouter.verbTable.count == 11)
        #expect(Set(PreRouter.verbTable.map(\.0)).count == 11)
        #expect(PreRouter.refusalTable.count == 4)
        for row in PreRouter.verbTable { _ = row.1.matches("probe") }
        for row in PreRouter.refusalTable { _ = row.pattern.matches("probe") }
        #expect(PreRouter.verbs(in: "send this to a@b.c and remind me") == [.send, .remind])
        #expect(PreRouter.verbs(in: "make it shorter").isEmpty)
    }

    @Test func detectorFindsAddressesAndLinks() {
        let found = PreRouter.detect(in: "Mail anna@example.com or see https://example.com/x by 10 October 2026")
        #expect(found.emails == ["anna@example.com"])
        #expect(found.urls.map(\.absoluteString) == ["https://example.com/x"])
        #expect(found.hasDate)
        #expect(PreRouter.emails(in: "a@b.c, d.e+f@g-h.io") == ["a@b.c", "d.e+f@g-h.io"])
    }

    @Test func titlesAreFirstLinesTrimmedToSixtyCharacters() {
        #expect(SelectionText.title("\n  Dentist Thursday 3pm, Hauptstrasse 12 \nsecond line", dropping: "Thursday 3pm") == "Dentist, Hauptstrasse 12")
        let long = String(repeating: "abcde ", count: 20)
        #expect(SelectionText.title(long).count <= 60)
        #expect(SelectionText.title(long) == String(repeating: "abcde ", count: 10).trimmingCharacters(in: .whitespaces))
        #expect(SelectionText.collapsed("a   b\n\nc", limit: 3) == "a b")
    }

    @Test func localPrefixIsStripped() {
        let local = PreRouter.stripLocalPrefix("/local  hello")
        #expect(local.text == "hello" && local.isLocal)
        let plain = PreRouter.stripLocalPrefix("hello /local")
        #expect(plain.text == "hello /local" && !plain.isLocal)
        #expect(PreRouter.styleRest(of: "send this to anna@example.com in formal style, keep it short") == "in formal style, keep it short")
        #expect(PreRouter.shortcutName(in: "run \"Make Tweet\" with this") == "Make Tweet")
        #expect(PreRouter.translationTarget(in: "translate to simplified chinese") == "Simplified Chinese")
        #expect(PreRouter.searchObject(in: "search the web for cheap flights") == "cheap flights")
        #expect(PreRouter.searchObject(in: "search for this") == nil)
    }
}

// MARK: - DateParsing

struct DateParsingTests {
    @Test func fridayMeansTheNextFridayAtNine() throws {
        let match = try #require(Fixed.parser.firstDate(in: "Friday"))
        #expect(match.date == Fixed.date(2026, 10, 9, 9, 0))
        #expect(match.text == "Friday")
        #expect(match.precision == .day)
    }

    @Test func tomorrowAtThree() throws {
        let match = try #require(Fixed.parser.firstDate(in: "tomorrow 3pm"))
        #expect(match.date == Fixed.date(2026, 10, 7, 15, 0))
        #expect(match.text == "tomorrow 3pm")
        #expect(match.precision == .time)
    }

    @Test func nextWeekIsARangeStartingMonday() throws {
        let match = try #require(Fixed.parser.firstDate(in: "Lunch with Sam next week"))
        #expect(match.date == Fixed.date(2026, 10, 12, 9, 0))
        #expect(match.text == "next week")
        #expect(match.precision == .week)
    }

    @Test func tenOctoberIsThisYearAndNoYearIsInvented() throws {
        let match = try #require(Fixed.parser.firstDate(in: "due 10 Oct"))
        #expect(match.date == Fixed.date(2026, 10, 10, 9, 0))
        #expect(match.text == "10 Oct")
        #expect(match.precision == .day)
        // A month and day already past means its next occurrence.
        #expect(Fixed.parser.firstDate(in: "5 Mar")?.date == Fixed.date(2027, 3, 5, 9, 0))
        // An explicit year is kept as written.
        #expect(Fixed.parser.firstDate(in: "10 Oct 2025")?.date == Fixed.date(2025, 10, 10, 9, 0))
        #expect(Fixed.parser.firstDate(in: "Oct 10, 2026 at 5pm")?.date == Fixed.date(2026, 10, 10, 17, 0))
        #expect(Fixed.parser.firstDate(in: "2026-12-24")?.date == Fixed.date(2026, 12, 24, 9, 0))
    }

    @Test func inTwoHours() throws {
        let match = try #require(Fixed.parser.firstDate(in: "in 2 hours"))
        #expect(match.date == Fixed.date(2026, 10, 6, 12, 0))
        #expect(match.text == "in 2 hours")
        #expect(match.precision == .time)
        #expect(Fixed.parser.firstDate(in: "in half an hour")?.date == Fixed.date(2026, 10, 6, 10, 30))
        #expect(Fixed.parser.firstDate(in: "in three days")?.date == Fixed.date(2026, 10, 9, 10, 0))
    }

    @Test func timesAttachToDaysOnEitherSide() {
        #expect(Fixed.parser.firstDate(in: "Dentist Thursday 3pm, Hauptstrasse 12") == DateParsing.Match(date: Fixed.date(2026, 10, 8, 15, 0), text: "Thursday 3pm", precision: .time))
        #expect(Fixed.parser.firstDate(in: "3pm on Friday") == DateParsing.Match(date: Fixed.date(2026, 10, 9, 15, 0), text: "3pm on Friday", precision: .time))
        #expect(Fixed.parser.firstDate(in: "tomorrow at 15:30")?.date == Fixed.date(2026, 10, 7, 15, 30))
        #expect(Fixed.parser.firstDate(in: "Tuesday")?.date == Fixed.date(2026, 10, 13, 9, 0))
        #expect(Fixed.parser.firstDate(in: "tonight")?.date == Fixed.date(2026, 10, 6, 19, 0))
    }

    @Test func aTimeAloneIsTodayOrTomorrow() {
        #expect(Fixed.parser.firstDate(in: "at 5") == DateParsing.Match(date: Fixed.date(2026, 10, 6, 17, 0), text: "at 5", precision: .time))
        #expect(Fixed.parser.firstDate(in: "9am") == DateParsing.Match(date: Fixed.date(2026, 10, 7, 9, 0), text: "9am", precision: .time))
        #expect(Fixed.parser.firstDate(in: "noon")?.date == Fixed.date(2026, 10, 6, 12, 0))
    }

    @Test func plainTextHasNoDate() {
        #expect(Fixed.parser.firstDate(in: "Order 4471 arrived late") == nil)
        #expect(Fixed.parser.firstDate(in: "") == nil)
    }

    /// What NSDataDetector itself makes of the same phrases on this runner,
    /// for the record: the grammar above exists because it is wall-clock bound.
    @Test func recordsWhatTheDataDetectorSees() {
        let probes = ["Friday", "next week", "10 Oct", "tomorrow 3pm", "in 2 hours", "Hauptstrasse 12", "1 Infinite Loop, Cupertino, CA 95014"]
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue | NSTextCheckingResult.CheckingType.address.rawValue)
        var lines = ["NSDataDetector on \(Date()):"]
        for probe in probes {
            let matches = detector?.matches(in: probe, range: NSRange(probe.startIndex..., in: probe)) ?? []
            let described = matches.map { match -> String in
                if let date = match.date { return "date \(date)" }
                if let address = match.addressComponents { return "address \(address)" }
                return "other"
            }
            lines.append("  \"\(probe)\" -> \(described.isEmpty ? "nothing" : described.joined(separator: "; "))")
        }
        Measurements.record(lines, in: "router.txt")
    }
}

// MARK: - Actions

struct ActionsPureTests {
    @Test func mailtoCarriesRecipientsSubjectAndBody() {
        let url = MailCompose.mailtoURL(to: ["dana@example.com", "lee@example.com"], subject: "Q4 & plans", body: "line one\nline two")
        #expect(url?.absoluteString == "mailto:dana@example.com,lee@example.com?subject=Q4%20%26%20plans&body=line%20one%0D%0Aline%20two")
        #expect(MailCompose.mailtoURL(to: [], subject: nil, body: "")?.absoluteString == "mailto:")
        #expect(MailCompose.mailtoURL(to: [], subject: nil, body: "hi ?=+")?.absoluteString == "mailto:?body=hi%20%3F%3D%2B")
    }

    @Test func appleScriptQuoting() {
        #expect(AppleScriptEscaping.quoted("a\"b\\c\nd") == "\"a\\\"b\\\\c\\nd\"")
        #expect(AppleScriptEscaping.quoted("tab\there\r\nnext") == "\"tab\\there\\nnext\"")
        #expect(AppleScriptEscaping.quoted("") == "\"\"")
        #expect(AppleScriptEscaping.htmlParagraphs("a & b\n\n<c>") == "<div>a &amp; b</div><div><br></div><div>&lt;c&gt;</div>")
        let script = NotesScript.source(title: "Shopping \"list\"", body: "milk\neggs")
        #expect(script.hasPrefix("tell application \"Notes\"\n\tmake new note at folder \"Notes\" with properties {name:\"Shopping \\\"list\\\"\", body:\""))
        #expect(script.contains("<div><h1>Shopping &quot;list&quot;</h1></div><div>milk</div><div>eggs</div>"))
        #expect(script.hasSuffix("\"}\nend tell"))
        #expect(!NotesScript.source(title: "t", body: "b", folder: nil).contains("at folder"))
    }

    @Test func shortcutsArguments() {
        #expect(ShortcutsCommand.arguments(name: "Make Tweet", inputPath: "/tmp/in.txt", outputPath: "/tmp/out.txt")
                == ["run", "Make Tweet", "--input-path", "/tmp/in.txt", "--output-path", "/tmp/out.txt"])
        #expect(ShortcutsCommand.executable == "/usr/bin/shortcuts")
    }

    @Test func searchURLEncodesEverythingButUnreservedCharacters() {
        #expect(SearchURL.make(query: "hello world & café")?.absoluteString == "https://duckduckgo.com/?q=hello%20world%20%26%20caf%C3%A9")
        #expect(SearchURL.make(query: "  a-b_c.d~e ")?.absoluteString == "https://duckduckgo.com/?q=a-b_c.d~e")
        #expect(SearchURL.make(query: "   ") == nil)
        #expect(SearchURL.make(query: "x")?.query?.contains("&") == false)
    }

    @Test func reminderDraftTrimsAndMakesComponents() {
        let due = Fixed.date(2026, 10, 9, 9, 30)
        let draft = ReminderDraft(title: "  Call mum \n", due: due)
        #expect(draft.title == "Call mum")
        let components = draft.dueComponents(calendar: Fixed.calendar)
        #expect(components?.year == 2026 && components?.month == 10 && components?.day == 9)
        #expect(components?.hour == 9 && components?.minute == 30)
        #expect(ReminderDraft(title: "   ", due: nil).title == "Reminder")
        #expect(ReminderDraft(title: "x", due: nil).dueComponents() == nil)
        let dayOnly = ReminderDraft(title: "x", due: due, hasTime: false).dueComponents(calendar: Fixed.calendar)
        #expect(dayOnly?.day == 9 && dayOnly?.hour == nil && dayOnly?.minute == nil)
    }

    @Test func eventDraftDefaultsToOneHour() {
        let start = Fixed.date(2026, 10, 8, 15, 0)
        let draft = EventDraft(title: " Dentist ", start: start, location: "  ")
        #expect(draft.title == "Dentist")
        #expect(draft.end == start.addingTimeInterval(3600))
        #expect(draft.location == nil)
        #expect(EventDraft(title: "", start: start, end: start.addingTimeInterval(-60)).end == start.addingTimeInterval(3600))
        #expect(EventDraft(title: "", start: start).title == "Event")
        let given = EventDraft(title: "x", start: start, end: start.addingTimeInterval(1800), location: "Hauptstrasse 12")
        #expect(given.end == start.addingTimeInterval(1800))
        #expect(given.location == "Hauptstrasse 12")
    }

    /// Dictionary Services needs no permission; if the runner's dictionary
    /// assets are missing the result is recorded rather than failed.
    @Test func defineUsesTheSystemDictionary() {
        let definition = Define.lookup("serendipity")
        if let definition {
            #expect(!definition.isEmpty)
            Measurements.record(["Define(\"serendipity\") -> \(definition.prefix(120))"], in: "actions.txt")
        } else {
            Measurements.record(["Define(\"serendipity\") returned nil on this runner (no dictionary assets?)"], in: "actions.txt")
        }
        #expect(Define.lookup("   ") == nil)
    }
}

@MainActor
struct ActionsStoreTests {
    @Test func historyRoundTripCapAndClear() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gyozaclikr-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "GyozaclikrTests.history.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = HistoryStore(directory: directory, defaults: defaults)
        #expect(store.limit == 50)
        #expect(store.entries.isEmpty)
        defaults.set(3, forKey: SettingsKey.historyLimit)
        #expect(store.limit == 3)

        for index in 1...5 {
            store.append(HistoryEntry(date: Fixed.date(2026, 10, index), requestText: "request \(index)", chip: index == 1 ? "fix" : nil,
                                      selectionPreview: "selection \(index)", answerText: "answer \(index)", engine: "apple"))
        }
        #expect(store.entries.count == 3)
        #expect(store.entries.map(\.requestText) == ["request 5", "request 4", "request 3"])
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.json").path))

        let reloaded = HistoryStore(directory: directory, defaults: defaults)
        #expect(reloaded.entries.map(\.id) == store.entries.map(\.id))
        #expect(reloaded.entries.map(\.answerText) == ["answer 5", "answer 4", "answer 3"])
        #expect(reloaded.entries.first?.date == Fixed.date(2026, 10, 5))

        reloaded.clear()
        #expect(reloaded.entries.isEmpty)
        #expect(HistoryStore.load(from: reloaded.fileURL).isEmpty)
        #expect(HistoryStore.load(from: directory.appendingPathComponent("missing.json")).isEmpty)
    }

    @Test func pasteboardSnapshotRestoresEveryItem() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("GyozaclikrTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        let snapshot = PasteboardSnapshot.take(from: pasteboard)
        #expect(snapshot.items.count == 1)
        pasteboard.clearContents()
        pasteboard.setString("after", forType: .string)
        pasteboard.setData(Data(), forType: PasteboardSnapshot.transientType)
        snapshot.restore(to: pasteboard, transient: false)
        #expect(pasteboard.string(forType: .string) == "before")
        #expect(pasteboard.data(forType: PasteboardSnapshot.transientType) == nil)
        pasteboard.clearContents()
        let empty = PasteboardSnapshot.take(from: pasteboard)
        pasteboard.setString("stray", forType: .string)
        empty.restore(to: pasteboard, transient: false)
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test func permissionStatesMap() {
        #expect(ActionPermissions.state(EKAuthorizationStatus.fullAccess) == .granted)
        #expect(ActionPermissions.state(EKAuthorizationStatus.writeOnly) == .granted)
        #expect(ActionPermissions.state(EKAuthorizationStatus.denied) == .denied)
        #expect(ActionPermissions.state(EKAuthorizationStatus.notDetermined) == .notDetermined)
        #expect(ActionPermissions.state(CNAuthorizationStatus.authorized) == .granted)
        #expect(ActionPermissions.state(CNAuthorizationStatus.restricted) == .denied)
        #expect(ActionPermissions.privacyPaneURL(for: .automationNotes)?.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        let permissions = ActionPermissions()
        // Nothing has run a Notes script in this process, so Automation is undetermined.
        #expect(permissions.state(of: .automationNotes) == .notDetermined)
        #expect(permissions.state(of: .accessibility) == .unknown)
        // EventKit and Contacts answer without prompting; any state is acceptable on CI, but it must answer.
        _ = permissions.state(of: .reminders)
        _ = permissions.state(of: .calendar)
        _ = permissions.state(of: .contacts)
    }
}

// MARK: - Helpers

/// Facts measured on the runner, printed by CI next to the snapshots.
nonisolated enum Measurements {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gyozaclikr-measurements", isDirectory: true)

    static func record(_ lines: [String], in file: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(file)
        let text = lines.joined(separator: "\n") + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
