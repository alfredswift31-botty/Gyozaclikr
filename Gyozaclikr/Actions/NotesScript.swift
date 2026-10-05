import Foundation

/// AppleScript string and HTML escaping, pure so the tests can pin it.
nonisolated enum AppleScriptEscaping {
    /// `text` as an AppleScript string literal: backslashes and quotes
    /// escaped, line breaks and tabs as the \n, \r and \t escapes.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for character in text.replacingOccurrences(of: "\r\n", with: "\n") {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(character)
            }
        }
        return out + "\""
    }

    static func htmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Each line as a Notes paragraph; blank lines stay blank.
    static func htmlParagraphs(_ body: String) -> String {
        body.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let escaped = htmlEscaped(String(line))
                return escaped.isEmpty ? "<div><br></div>" : "<div>\(escaped)</div>"
            }
            .joined()
    }
}

/// The script that makes a note. Notes takes its title from the body's first
/// line, so the title goes in as a heading too.
nonisolated enum NotesScript {
    static func source(title: String, body: String, folder: String? = "Notes") -> String {
        let name = AppleScriptEscaping.quoted(title)
        let html = "<div><h1>" + AppleScriptEscaping.htmlEscaped(title) + "</h1></div>" + AppleScriptEscaping.htmlParagraphs(body)
        let target = folder.map { " at folder \(AppleScriptEscaping.quoted($0))" } ?? ""
        return "tell application \"Notes\"\n\tmake new note\(target) with properties {name:\(name), body:\(AppleScriptEscaping.quoted(html))}\nend tell"
    }

    /// A harmless script whose only effect is the Automation prompt.
    static let probe = "tell application \"Notes\" to get name"
}

/// Runs the Notes scripts and remembers how Automation answered: there is no
/// status API, so it is not determined until the first run.
final class NotesWriter {
    static var automationState: PermissionState = .notDetermined

    static let notAllowed = "Notes automation is not allowed. Grant it in System Settings › Privacy & Security › Automation."

    func save(title: String, body: String) -> ActionOutcome {
        let outcome = Self.run(NotesScript.source(title: title, body: body, folder: "Notes"))
        if case .failed(let message) = outcome, message != Self.notAllowed {
            // The "Notes" folder is missing in some accounts: let Notes pick one.
            return Self.run(NotesScript.source(title: title, body: body, folder: nil))
        }
        return outcome
    }

    /// Runs `source`; maps -1743 (errAEEventNotPermitted) to the grant message.
    @discardableResult
    static func run(_ source: String) -> ActionOutcome {
        guard let script = NSAppleScript(source: source) else { return .failed("Couldn't build the Notes script.") }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        guard let error else {
            automationState = .granted
            return .done("Saved to Notes")
        }
        let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
        if number == -1743 {
            automationState = .denied
            return .failed(notAllowed)
        }
        // Any other error came back from Notes itself, so the event was allowed.
        automationState = .granted
        let message = (error[NSAppleScript.errorMessage] as? String) ?? "Notes returned error \(number)."
        return .failed("Notes: \(message)")
    }
}
