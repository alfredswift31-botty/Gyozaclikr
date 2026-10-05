import EventKit
import Foundation

/// A reminder as the confirmation card showed it: a trimmed title and the due
/// date as calendar components. Pure, so the tests can check it.
nonisolated struct ReminderDraft: Hashable, Sendable {
    let title: String
    let due: Date?
    /// Whether `due` carries a time; a day-only reminder has no hour.
    let hasTime: Bool

    init(title: String, due: Date?, hasTime: Bool = true) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = trimmed.isEmpty ? "Reminder" : trimmed
        self.due = due
        self.hasTime = hasTime
    }

    func dueComponents(calendar: Calendar = .autoupdatingCurrent) -> DateComponents? {
        guard let due else { return nil }
        let units: Set<Calendar.Component> = hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
        return calendar.dateComponents(units, from: due)
    }
}

/// An event: a trimmed title, a start, an end one hour later unless given.
nonisolated struct EventDraft: Hashable, Sendable {
    static let defaultDuration: TimeInterval = 3600

    let title: String
    let start: Date
    let end: Date
    let location: String?

    init(title: String, start: Date, end: Date? = nil, location: String? = nil) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = trimmed.isEmpty ? "Event" : trimmed
        self.start = start
        if let end, end > start { self.end = end } else { self.end = start.addingTimeInterval(Self.defaultDuration) }
        let place = location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.location = place.isEmpty ? nil : place
    }
}

/// EventKit writes. Events use write-only access; reminders have no write-only
/// level on macOS, so `requestFullAccessToReminders` is the only grant, and
/// the app still never reads them.
final class EventKitWriter {
    private let store = EKEventStore()

    static let remindersDenied = "Reminders access was not granted. Allow it in System Settings › Privacy & Security › Reminders."
    static let calendarDenied = "Calendar access was not granted. Allow it in System Settings › Privacy & Security › Calendars."

    func addReminder(_ draft: ReminderDraft) async -> ActionOutcome {
        do {
            guard try await store.requestFullAccessToReminders() else { return .failed(Self.remindersDenied) }
        } catch {
            return .failed("Reminders access failed: \(error.localizedDescription)")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = draft.title
        reminder.calendar = store.defaultCalendarForNewReminders()
        reminder.dueDateComponents = draft.dueComponents()
        if let due = draft.due, draft.hasTime { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
        do {
            try store.save(reminder, commit: true)
        } catch {
            return .failed("Couldn't add the reminder: \(error.localizedDescription)")
        }
        return .done("Added to Reminders")
    }

    func addEvent(_ draft: EventDraft) async -> ActionOutcome {
        do {
            guard try await store.requestWriteOnlyAccessToEvents() else { return .failed(Self.calendarDenied) }
        } catch {
            return .failed("Calendar access failed: \(error.localizedDescription)")
        }
        guard let calendar = store.defaultCalendarForNewEvents else { return .failed("There is no default calendar to add to.") }
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        event.location = draft.location
        event.calendar = calendar
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            return .failed("Couldn't add the event: \(error.localizedDescription)")
        }
        return .done("Added to Calendar")
    }
}
