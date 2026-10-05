import Foundation

/// Every argument of an outward action, in words, for the confirmation
/// card and for VoiceOver (docs/DESIGN.md "Confirmation"). Dates read
/// "Fri 10 Oct, 09:00"; the body shows its first two lines. Pure.
nonisolated enum ConfirmationRows {
    struct Row: Hashable, Sendable {
        var label: String
        var value: String
        /// Lines the card allows the value before it clips (the body gets two).
        var lines: Int = 1
    }

    static func rows(for proposal: ActionProposal) -> [Row] {
        switch proposal {
        case .sendMail(let to, let subject, let body):
            [Row(label: "To", value: to.joined(separator: ", ")),
             Row(label: "Subject", value: subject),
             Row(label: "Body", value: body, lines: 2)]
        case .createReminder(let title, let due, let dueText):
            [Row(label: "Title", value: title),
             Row(label: "When", value: when(due, dueText))]
        case .createEvent(let title, let start, let end, let location, let whenText):
            [Row(label: "Title", value: title),
             Row(label: "Starts", value: when(start, whenText)),
             Row(label: "Ends", value: end.map(format) ?? "–"),
             Row(label: "Where", value: location ?? "–")]
        case .saveNote(let title, let body):
            [Row(label: "Title", value: title),
             Row(label: "Body", value: body, lines: 2)]
        case .runShortcut(let name, let input):
            [Row(label: "Shortcut", value: name),
             Row(label: "Input", value: input, lines: 2)]
        case .openURL(let url):
            [Row(label: "Link", value: url.absoluteString)]
        case .search(let query):
            [Row(label: "Search", value: query)]
        }
    }

    /// The verb on the card's button: "Send", "Add", "Save", "Run".
    static func verb(for proposal: ActionProposal) -> String {
        switch proposal {
        case .sendMail: "Send"
        case .createReminder, .createEvent: "Add"
        case .saveNote: "Save"
        case .runShortcut: "Run"
        case .openURL: "Open"
        case .search: "Search"
        }
    }

    /// What Edit puts back in the input: the proposal as the user might have typed it.
    static func editText(for proposal: ActionProposal) -> String {
        switch proposal {
        case .sendMail(let to, let subject, _): "send this to \(to.joined(separator: ", ")) · \(subject)"
        case .createReminder(let title, _, let dueText): "remind me \(title)" + (dueText.map { " \($0)" } ?? "")
        case .createEvent(let title, _, _, _, let whenText): "add event \(title)" + (whenText.map { " \($0)" } ?? "")
        case .saveNote(let title, _): "save to notes \(title)"
        case .runShortcut(let name, _): "run shortcut \(name)"
        case .openURL(let url): "open \(url.absoluteString)"
        case .search(let query): "search \(query)"
        }
    }

    private static func when(_ date: Date?, _ text: String?) -> String {
        if let date { return format(date) }
        return text ?? "no date"
    }

    /// "Fri 10 Oct, 09:00": the weekday and the clock, never a numeric date.
    static func format(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE d MMM, HH:mm"
        return formatter.string(from: date)
    }

    /// One sentence VoiceOver reads for the whole card.
    static func spoken(_ proposal: ActionProposal) -> String {
        ([proposal.title] + rows(for: proposal).map { "\($0.label): \($0.value)" }).joined(separator: ". ")
    }
}
