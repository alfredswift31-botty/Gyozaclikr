import Foundation

/// Dates from text, never from the model. A small grammar covers the relative
/// forms people type ("Friday", "tomorrow 3pm", "in 2 hours", "next week",
/// "10 Oct"), anchored to an injectable `now` and calendar so it is testable;
/// NSDataDetector, which is anchored to the wall clock, handles the absolute
/// forms it is good at ("October 10, 2026 at 5pm", "10/10/26"). Rules:
/// "Friday" is the next Friday; a time without a day is today, or tomorrow
/// once it has passed; a day without a time is at `defaultHour`; a month and
/// day without a year is its next occurrence, so no year is invented.
nonisolated struct DateParsing: Sendable {
    enum Precision: Hashable, Sendable {
        /// An hour and minute were given.
        case time
        /// A day only; `date` is at `defaultHour`.
        case day
        /// A range ("next week"): `date` is its first day and the box should ask.
        case week
    }

    struct Match: Hashable, Sendable {
        let date: Date
        /// The words that were parsed, as they appear in the text.
        let text: String
        let precision: Precision
    }

    let now: Date
    let calendar: Calendar

    /// The hour a day-only date gets: "Friday" means Friday 09:00.
    static let defaultHour = 9

    init(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        self.now = now
        self.calendar = calendar
    }

    // MARK: Grammar

    private enum DayKind { case today, tonight, thisPart, tomorrow, dayAfterTomorrow, weekday, nextWeek, nextMonth, relative, dayMonth, monthDay, iso }

    private static let preposition = #"(?:\b(?:on|by|for|until|before|this|next|coming|the)\s+)?"#
    private static let months = #"(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"#

    private static let dayTable: [(DayKind, Pattern)] = [
        (.dayAfterTomorrow, Pattern(preposition + #"\b(?:the\s+)?day\s+after\s+tomorrow\b"#)),
        (.tomorrow, Pattern(preposition + #"\btomorrow\b"#)),
        (.today, Pattern(preposition + #"\btoday\b"#)),
        (.tonight, Pattern(#"\btonight\b"#)),
        (.thisPart, Pattern(#"\bthis\s+(morning|afternoon|evening)\b"#)),
        (.nextWeek, Pattern(#"\bnext\s+week\b"#)),
        (.nextMonth, Pattern(#"\bnext\s+month\b"#)),
        (.weekday, Pattern(preposition + #"\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday|tues|weds|thur|thurs|(?:mon|tue|wed|thu|fri|sat|sun)\.)(?![a-z])"#)),
        (.relative, Pattern(#"\bin\s+(\d+|an?|one|two|three|four|five|six|seven|eight|nine|ten|twelve|fifteen|twenty|thirty|forty|forty-five|half\s+an?)\s+(minutes?|mins?|hours?|hrs?|days?|weeks?|months?)\b"#)),
        (.iso, Pattern(#"\b(\d{4})-(\d{2})-(\d{2})\b"#)),
        (.dayMonth, Pattern(preposition + #"\b(\d{1,2})(?:st|nd|rd|th)?(?:\s+of)?\s+"# + months + #"\b\.?(?:,?\s+(\d{4}))?"#)),
        (.monthDay, Pattern(preposition + #"\b"# + months + #"\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?![\d:])(?:,?\s+(\d{4}))?"#)),
    ]

    /// A time of day: "3pm", "3:30 pm", "15:00", "at 5", "noon". Groups: 1-3
    /// hour, minute, a/p; 4-5 hour, minute (24 h); 6 hour after "at"; 7 word.
    private static let time = Pattern(#"(?:\bat\s+)?(?:\b(\d{1,2})(?::(\d{2}))?\s*([ap])\.?m\.?(?![a-z])|\b(\d{1,2}):(\d{2})(?![\d:])|\bat\s+(\d{1,2})(?![\d:])|\b(noon|midday|midnight)\b)"#)
    private static let timeLead = Pattern(#"^[\s,]*"#)
    private static let timeBefore = Pattern(#"((?:\bat\s+)?(?:\d{1,2}(?::\d{2})?\s*[ap]\.?m\.?|\d{1,2}:\d{2}|noon|midday|midnight))[\s,]*(?:on\s+)?$"#)

    // MARK: Parsing

    /// The first date in `text`, with the words it came from.
    func firstDate(in text: String) -> Match? {
        guard !text.isEmpty else { return nil }
        let whole = NSRange(text.startIndex..., in: text)
        // The earliest day expression wins; the longest on a tie.
        var earliest: (kind: DayKind, pattern: Pattern, match: NSTextCheckingResult)?
        for (kind, pattern) in Self.dayTable {
            guard let match = pattern.regex.firstMatch(in: text, range: whole) else { continue }
            if let current = earliest {
                let better = match.range.location < current.match.range.location
                    || (match.range.location == current.match.range.location && match.range.length > current.match.range.length)
                if !better { continue }
            }
            earliest = (kind, pattern, match)
        }
        if let earliest, let resolved = resolve(earliest.kind, earliest.match, pattern: earliest.pattern, in: text) {
            return resolved
        }
        if let match = Self.time.first(in: text), let clock = Self.clock(from: match, in: text) {
            var date = at(hour: clock.hour, minute: clock.minute, of: now)
            if date <= now { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
            return Match(date: date, text: Self.trimmed(match, in: text), precision: .time)
        }
        return detectorFallback(in: text)
    }

    private func resolve(_ kind: DayKind, _ match: NSTextCheckingResult, pattern: Pattern, in text: String) -> Match? {
        let day: Date
        var precision: Precision = .day
        var fixedTime: (hour: Int, minute: Int)?
        switch kind {
        case .today: day = now
        case .tonight: day = now; fixedTime = (19, 0)
        case .thisPart:
            day = now
            switch (pattern.group(1, of: match, in: text) ?? "").lowercased() {
            case "morning": fixedTime = (9, 0)
            case "afternoon": fixedTime = (15, 0)
            default: fixedTime = (19, 0)
            }
        case .tomorrow: day = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        case .dayAfterTomorrow: day = calendar.date(byAdding: .day, value: 2, to: now) ?? now
        case .weekday:
            guard let name = pattern.group(1, of: match, in: text), let weekday = Self.weekday(named: name),
                  let next = calendar.nextDate(after: now, matching: DateComponents(weekday: weekday), matchingPolicy: .nextTime) else { return nil }
            day = next
        case .nextWeek:
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
            day = interval.end
            precision = .week
        case .nextMonth:
            guard let interval = calendar.dateInterval(of: .month, for: now) else { return nil }
            day = interval.end
            precision = .week
        case .relative:
            guard let amount = pattern.group(1, of: match, in: text), let unit = pattern.group(2, of: match, in: text) else { return nil }
            let isHalf = amount.lowercased().hasPrefix("half")
            guard let count = isHalf ? 1 : Self.number(amount) else { return nil }
            var component: Calendar.Component = .minute
            var value = count
            let unitName = unit.lowercased()
            if unitName.hasPrefix("h") { value = isHalf ? 30 : count * 60 }
            else if unitName.hasPrefix("d") { component = .day }
            else if unitName.hasPrefix("w") { component = .day; value = count * 7 }
            else if unitName.hasPrefix("mo") { component = .month }
            guard let date = calendar.date(byAdding: component, value: value, to: now) else { return nil }
            return Match(date: date, text: Self.trimmed(match, in: text), precision: .time)
        case .iso:
            guard let y = pattern.group(1, of: match, in: text), let m = pattern.group(2, of: match, in: text), let d = pattern.group(3, of: match, in: text),
                  let date = calendar.date(from: DateComponents(year: Int(y), month: Int(m), day: Int(d))) else { return nil }
            day = date
        case .dayMonth, .monthDay:
            let dayText = kind == .dayMonth ? pattern.group(1, of: match, in: text) : pattern.group(2, of: match, in: text)
            let monthText = kind == .dayMonth ? pattern.group(2, of: match, in: text) : pattern.group(1, of: match, in: text)
            guard let dayText, let monthText, let dayNumber = Int(dayText), let month = Self.month(named: monthText) else { return nil }
            let yearText = pattern.group(3, of: match, in: text)
            guard let date = nextOccurrence(month: month, day: dayNumber, year: yearText.flatMap { Int($0) }) else { return nil }
            day = date
        }

        var range = match.range
        var clock = fixedTime
        if clock == nil, precision == .day {
            // A time right after ("Thursday 3pm", "tomorrow at 15:00") or before ("3pm on Friday").
            if let found = timeAfter(range, in: text) ?? timeBefore(range, in: text) {
                clock = (found.hour, found.minute)
                range = NSUnionRange(range, found.range)
            }
        }
        let date: Date
        if let clock {
            date = at(hour: clock.hour, minute: clock.minute, of: day)
            precision = .time
        } else {
            date = at(hour: Self.defaultHour, minute: 0, of: day)
        }
        guard let swiftRange = Range(range, in: text) else { return nil }
        return Match(date: date, text: String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines), precision: precision)
    }

    private func timeAfter(_ range: NSRange, in text: String) -> (hour: Int, minute: Int, range: NSRange)? {
        let start = range.location + range.length
        let tail = NSRange(location: start, length: (text as NSString).length - start)
        guard tail.length > 0, let lead = Self.timeLead.regex.firstMatch(in: text, options: [.anchored], range: tail) else { return nil }
        let after = NSRange(location: lead.range.location + lead.range.length, length: tail.length - lead.range.length)
        guard after.length > 0, let match = Self.time.regex.firstMatch(in: text, options: [.anchored], range: after),
              let clock = Self.clock(from: match, in: text) else { return nil }
        return (clock.hour, clock.minute, match.range)
    }

    private func timeBefore(_ range: NSRange, in text: String) -> (hour: Int, minute: Int, range: NSRange)? {
        let head = NSRange(location: 0, length: range.location)
        guard head.length > 0, let before = Self.timeBefore.regex.firstMatch(in: text, range: head) else { return nil }
        let timeRange = before.range(at: 1)
        guard let match = Self.time.regex.firstMatch(in: text, options: [.anchored], range: timeRange),
              let clock = Self.clock(from: match, in: text) else { return nil }
        return (clock.hour, clock.minute, timeRange)
    }

    private func detectorFallback(in text: String) -> Match? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let date = match.date, let range = Range(match.range, in: text) else { return nil }
        let matched = String(text[range])
        let hasTime = matched.range(of: #"\d:\d|\d\s*[ap]\.?m|noon|midnight"#, options: [.regularExpression, .caseInsensitive]) != nil
        return Match(date: date, text: matched, precision: hasTime ? .time : .day)
    }

    // MARK: Helpers

    private func at(hour: Int, minute: Int, of day: Date) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    /// The next `day`/`month` on or after today; an explicit year is kept as written.
    private func nextOccurrence(month: Int, day: Int, year: Int?) -> Date? {
        if let year { return calendar.date(from: DateComponents(year: year, month: month, day: day)) }
        let thisYear = calendar.component(.year, from: now)
        guard let candidate = calendar.date(from: DateComponents(year: thisYear, month: month, day: day)) else { return nil }
        if candidate >= calendar.startOfDay(for: now) { return candidate }
        return calendar.date(from: DateComponents(year: thisYear + 1, month: month, day: day))
    }

    private static func clock(from match: NSTextCheckingResult, in text: String) -> (hour: Int, minute: Int)? {
        if let word = time.group(7, of: match, in: text) {
            return word.lowercased() == "midnight" ? (0, 0) : (12, 0)
        }
        if let h = time.group(1, of: match, in: text), var hour = Int(h) {
            let minute = time.group(2, of: match, in: text).flatMap { Int($0) } ?? 0
            let isPM = (time.group(3, of: match, in: text) ?? "").lowercased() == "p"
            if hour == 12 { hour = isPM ? 12 : 0 } else if isPM { hour += 12 }
            guard hour < 24, minute < 60 else { return nil }
            return (hour, minute)
        }
        if let h = time.group(4, of: match, in: text), let hour = Int(h), let m = time.group(5, of: match, in: text), let minute = Int(m) {
            guard hour < 24, minute < 60 else { return nil }
            return (hour, minute)
        }
        if let h = time.group(6, of: match, in: text), let hour = Int(h) {
            // "at 5" is five in the afternoon; "at 9" is nine in the morning.
            guard (1...12).contains(hour) else { return nil }
            return ((1...6).contains(hour) ? hour + 12 : hour, 0)
        }
        return nil
    }

    private static func trimmed(_ match: NSTextCheckingResult, in text: String) -> String {
        guard let range = Range(match.range, in: text) else { return "" }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func weekday(named name: String) -> Int? {
        switch name.lowercased().prefix(3) {
        case "sun": 1
        case "mon": 2
        case "tue": 3
        case "wed": 4
        case "thu": 5
        case "fri": 6
        case "sat": 7
        default: nil
        }
    }

    private static func month(named name: String) -> Int? {
        let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let index = names.firstIndex(of: String(name.lowercased().prefix(3))) else { return nil }
        return index + 1
    }

    private static func number(_ word: String) -> Int? {
        if let n = Int(word) { return n }
        switch word.lowercased() {
        case "a", "an", "one": return 1
        case "two": return 2
        case "three": return 3
        case "four": return 4
        case "five": return 5
        case "six": return 6
        case "seven": return 7
        case "eight": return 8
        case "nine": return 9
        case "ten": return 10
        case "twelve": return 12
        case "fifteen": return 15
        case "twenty": return 20
        case "thirty": return 30
        case "forty": return 40
        case "forty-five": return 45
        default: return nil
        }
    }
}
