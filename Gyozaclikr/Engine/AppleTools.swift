import Foundation
import FoundationModels

// The four tools a free-text request may get. None of them acts: a call
// records an ActionProposal for the confirmation card and tells the model
// the action is ready. Arguments are flat strings, dates and recipients as
// the user wrote them; the app parses them (docs/research/product-and-ux.md §B).

/// Collects the proposals the tools record during one request.
actor ProposalLog {
    private(set) var proposals: [ActionProposal] = []

    func record(_ proposal: ActionProposal) {
        proposals.append(proposal)
    }
}

/// Turns tool strings into proposal fields.
nonisolated enum ToolArguments {
    /// "a@b.c, d@e.f g@h.i" → three recipients. Empty when nothing was given.
    static func recipients(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",; ").union(.whitespacesAndNewlines))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// nil for an empty or "none" answer, so the card shows no date rather than the word.
    static func optional(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || ["none", "n/a", "unknown", "null"].contains(trimmed.lowercased()) { return nil }
        return trimmed
    }
}

nonisolated struct SendMailTool: Tool {
    let name = "sendMail"
    let description = "Send an email the user asked for."
    let log: ProposalLog

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The recipients' email addresses, exactly as the user wrote them, comma separated.")
        var to: String
        @Guide(description: "The subject line.")
        var subject: String
        @Guide(description: "The message body.")
        var body: String
    }

    func call(arguments: Arguments) async throws -> String {
        await log.record(.sendMail(to: ToolArguments.recipients(arguments.to), subject: arguments.subject, body: arguments.body))
        return "The mail to \(arguments.to) is ready for the user to confirm."
    }
}

nonisolated struct CreateReminderTool: Tool {
    let name = "createReminder"
    let description = "Add a reminder the user asked for."
    let log: ProposalLog

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "A short reminder title.")
        var title: String
        @Guide(description: "When it is due, in the user's own words; empty if none was given.")
        var dueText: String
    }

    func call(arguments: Arguments) async throws -> String {
        await log.record(.createReminder(title: arguments.title, due: nil, dueText: ToolArguments.optional(arguments.dueText)))
        return "The reminder \"\(arguments.title)\" is ready for the user to confirm."
    }
}

nonisolated struct CreateEventTool: Tool {
    let name = "createEvent"
    let description = "Add a calendar event the user asked for."
    let log: ProposalLog

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "A short event title.")
        var title: String
        @Guide(description: "When it happens, in the user's own words; empty if none was given.")
        var whenText: String
        @Guide(description: "Where it happens, as written; empty if none was given.")
        var locationText: String
    }

    func call(arguments: Arguments) async throws -> String {
        await log.record(.createEvent(
            title: arguments.title, start: nil, end: nil,
            location: ToolArguments.optional(arguments.locationText), whenText: ToolArguments.optional(arguments.whenText)
        ))
        return "The event \"\(arguments.title)\" is ready for the user to confirm."
    }
}

nonisolated struct SaveNoteTool: Tool {
    let name = "saveNote"
    let description = "Save a note the user asked for."
    let log: ProposalLog

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "A short note title.")
        var title: String
        @Guide(description: "The note's text.")
        var body: String
    }

    func call(arguments: Arguments) async throws -> String {
        await log.record(.saveNote(title: arguments.title, body: arguments.body))
        return "The note \"\(arguments.title)\" is ready for the user to confirm."
    }
}
