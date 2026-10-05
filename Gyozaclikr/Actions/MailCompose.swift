import AppKit

/// Mail through the default mail client's compose window: no permission, the
/// user clicks Send (docs/research/system-integration.md §5). Fails when the
/// mailto handler is not a native app.
enum MailCompose {
    static func open(to recipients: [String], subject: String?, body: String) -> ActionOutcome {
        guard let service = NSSharingService(named: .composeEmail) else {
            return .failed("No mail app is set up for composing.")
        }
        service.recipients = recipients.isEmpty ? nil : recipients
        if let subject, !subject.isEmpty { service.subject = subject }
        let items: [Any] = [body]
        guard service.canPerform(withItems: items) else {
            return .failed("The default mail app can't compose a message.")
        }
        service.perform(withItems: items)
        return .done("Opened in Mail")
    }
}
