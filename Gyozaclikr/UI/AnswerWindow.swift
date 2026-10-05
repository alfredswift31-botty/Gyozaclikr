import AppKit
import SwiftUI

/// "Open in new window": a plain window with the answer in a scrolling
/// text view, for answers past the box's dozen lines. One window, reused.
final class AnswerWindow {
    static let shared = AnswerWindow()
    private var window: NSWindow?
    private var textView: NSTextView?

    static func show(answer: String, title: String = "Answer") {
        shared.present(answer, title: title)
    }

    private func present(_ answer: String, title: String) {
        if window == nil {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 480))
            scroll.hasVerticalScroller = true
            scroll.autoresizingMask = [.width, .height]
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false
            text.isRichText = false
            text.font = NSFont.systemFont(ofSize: 13)
            text.textContainerInset = NSSize(width: Theme.Space.l, height: Theme.Space.l)
            text.autoresizingMask = [.width]
            text.isVerticallyResizable = true
            text.textContainer?.widthTracksTextView = true
            scroll.documentView = text
            let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.contentView = scroll
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("AnswerWindow")
            self.window = window
            self.textView = text
        }
        window?.title = title
        textView?.string = MarkdownLite.plainText(answer)
        textView?.scroll(.zero)
        NSApplication.shared.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// History…: the Settings history pane in its own window.
final class HistoryWindow {
    static let shared = HistoryWindow()
    private var window: NSWindow?

    static func show(model: SettingsModel) {
        shared.present(model)
    }

    private func present(_ model: SettingsModel) {
        let view = Form { HistoryPane(model: model) }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Theme.canvas)
            .frame(width: Theme.Settings.width)
        if let window {
            window.contentView = NSHostingView(rootView: view)
        } else {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Theme.Settings.width, height: 480),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "History"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("HistoryWindow")
            self.window = window
        }
        NSApplication.shared.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
