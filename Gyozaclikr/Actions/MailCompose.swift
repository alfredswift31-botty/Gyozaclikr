import AppKit

/// Mail through whatever handles `mailto:`. Apple Mail gets the sharing
/// service (no length limit, the recipients and subject filled in). Any
/// other handler (Chrome with Gmail, Outlook, Spark…) gets a `mailto:` URL
/// with the recipients, the subject and the body, which is the one compose
/// request a browser understands: the sharing service opened Chrome on the
/// owner's Mac and did nothing else, because it hands the message to the
/// app's share extension, and browsers have none. A body longer than web
/// mail accepts in a URL goes to the clipboard as well, and the outcome
/// line says so.
enum MailCompose {
    /// Web mail cuts a `mailto:` body around here.
    static let urlBodyLimit = 1_800

    static func open(to recipients: [String], subject: String?, body: String) -> ActionOutcome {
        let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "mailto:")!)
        let name = handler.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? "the mail app"
        let isAppleMail = handler.flatMap { Bundle(url: $0)?.bundleIdentifier } == "com.apple.mail"
        if isAppleMail, let service = NSSharingService(named: .composeEmail) {
            service.recipients = recipients.isEmpty ? nil : recipients
            if let subject, !subject.isEmpty { service.subject = subject }
            let items: [Any] = [body]
            if service.canPerform(withItems: items) {
                service.perform(withItems: items)
                return .done("Opened in Mail")
            }
        }
        guard let url = mailtoURL(to: recipients, subject: subject, body: body) else {
            return .failed("Couldn't build the message.")
        }
        let long = body.count > urlBodyLimit
        if long { Replace.copy(body) }
        guard NSWorkspace.shared.open(url) else {
            return .failed("No app handles mailto: links. Choose a default email app in Mail › Settings › General.")
        }
        return .done(long ? "Opened in \(name); the full text is on the clipboard, since web mail cuts long messages" : "Opened in \(name)")
    }

    /// RFC 6068: `mailto:a@b.c,d@e.f?subject=…&body=…`, everything but
    /// unreserved characters percent-encoded, line ends as CRLF.
    nonisolated static func mailtoURL(to recipients: [String], subject: String?, body: String) -> URL? {
        var query: [String] = []
        if let subject, !subject.isEmpty { query.append("subject=" + encode(subject)) }
        if !body.isEmpty {
            let crlf = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
            query.append("body=" + encode(crlf))
        }
        let to = recipients.map(encode).joined(separator: ",")
        return URL(string: "mailto:" + to + (query.isEmpty ? "" : "?" + query.joined(separator: "&")))
    }

    private nonisolated static func encode(_ text: String) -> String {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~@")
        return text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}
