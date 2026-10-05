import AppKit

/// Performs what the router proposed and what the user pressed under an
/// answer. Local transforms write back into the source app (AX first, ⌘V
/// second); everything outward goes through Apple's own apps: Mail's compose
/// window, EventKit, Notes via AppleScript, the `shortcuts` tool, the
/// browser. The coordinator confirms proposals before calling `perform`.
final class ActionPerformer: ActionPerforming {
    /// The UI module's "Open in new window".
    let onOpenInWindow: (Answer) -> Void

    private let eventKit = EventKitWriter()
    private let notes = NotesWriter()
    private let shortcuts = ShortcutsRunner()

    init(onOpenInWindow: @escaping (Answer) -> Void) {
        self.onOpenInWindow = onOpenInWindow
    }

    func perform(_ proposal: ActionProposal) async -> ActionOutcome {
        switch proposal {
        case .sendMail(let to, let subject, let body):
            return MailCompose.open(to: to, subject: subject, body: body)
        case .createReminder(let title, let due, _):
            return await eventKit.addReminder(ReminderDraft(title: title, due: due))
        case .createEvent(let title, let start, let end, let location, _):
            guard let start else { return .failed("The event needs a date.") }
            return await eventKit.addEvent(EventDraft(title: title, start: start, end: end, location: location))
        case .saveNote(let title, let body):
            return notes.save(title: title, body: body)
        case .runShortcut(let name, let input):
            return await shortcuts.run(name: name, input: input)
        case .openURL(let url):
            return NSWorkspace.shared.open(url) ? .done("Opened") : .failed("Couldn't open \(url.absoluteString)")
        case .search(let query):
            guard let url = SearchURL.make(query: query) else { return .failed("Nothing to search for.") }
            return NSWorkspace.shared.open(url) ? .done("Searching") : .failed("Couldn't open the browser.")
        }
    }

    func perform(_ action: ResultAction, answer: Answer, selection: Selection) async -> ActionOutcome {
        switch action {
        case .replace:
            return await Replace.perform(answer.text, insertBelow: false, selection: selection)
        case .insertBelow:
            return await Replace.perform(answer.text, insertBelow: true, selection: selection)
        case .copy:
            Replace.copy(answer.text)
            return .done("Copied")
        case .send:
            return MailCompose.open(to: [], subject: nil, body: answer.text)
        case .openInWindow:
            onOpenInWindow(answer)
            return .done("Opened")
        }
    }

    func define(_ word: String) -> String? { Define.lookup(word) }
}
