# Gyozaclikr: system-integration research (macOS 26, Apple silicon, non-sandboxed, ad-hoc/self-signed)

Scope: the capture → box → act loop for a pointer-level assistant. Every section gives the recommended path, alternatives, the permission involved, and what breaks. Sources are collected at the end; inline references use [n].

## 0. Recommended architecture in one paragraph

A menu-bar agent (`LSUIElement`) owns one borderless **non-activating `NSPanel`** hosting SwiftUI. Entry points: (1) a global hotkey via Carbon `RegisterEventHotKey` (no permission, consumes the key), (2) an optional PopClip-style pill on mouse-up after a drag/double-click (global mouse monitor, no permission for mouse events; AX for the read), (3) a Services-menu item (zero permissions, works as a fallback everywhere), (4) a region-capture mode entered from the same hotkey (hold it) or the pill. On trigger, a `SelectionReader` tries AX (`AXSelectedText`, `AXSelectedTextRange`, `AXBoundsForRange`), then falls back to a ⌘C simulation with pasteboard save/restore, and refuses while Secure Input is on. Region capture uses `SCScreenshotManager.captureScreenshot(rect:configuration:)` (macOS 26) behind a per-display rubber-band overlay. The panel is anchored to the AX selection rectangle, else to `NSEvent.mouseLocation`, clamped to `visibleFrame`. Acting goes AX-set first, ⌘V fallback second, with explicit "Replace / Insert below / Copy / Mail" buttons. Sign with a **self-signed certificate**, not ad-hoc, or every rebuild silently loses Accessibility and Screen Recording.

## 1. Reading the selected text from any app

### Recommended: Accessibility API first

```swift
let sys = AXUIElementCreateSystemWide()
var focused: CFTypeRef?
AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused)
// then on `focused`:
//   kAXSelectedTextAttribute        -> String
//   kAXSelectedTextRangeAttribute   -> AXValue(CFRange)
//   kAXBoundsForRangeParameterizedAttribute (AXUIElementCopyParameterizedAttributeValue with the range) -> AXValue(CGRect), top-left origin, screen coords
```

Take the *focused* element from the system-wide element (not the frontmost app's `AXFocusedWindow`): that is what PopClip and Raycast do, and it is the only way to get the selection in the element that actually has it. Read `AXSelectedText` and, if it is empty, also try `AXValue` sliced by `AXSelectedTextRange` (some views return an empty `AXSelectedText` but a valid range). `AXBoundsForRange` gives the selection rectangle in **top-left-origin screen coordinates**; convert to AppKit by `y' = primaryScreen.height − (y + h)`.

Which apps answer (field experience, matches PopClip/Raycast reports [7][8][9]):

| Source app | `AXSelectedText` | `AXBoundsForRange` | Notes |
|---|---|---|---|
| Cocoa text (TextEdit, Notes, Mail, Xcode, Messages, most SwiftUI/AppKit apps) | yes | yes | Gold path; setting the selection also works. |
| Safari / WebKit web content | yes (on the focused `AXWebArea` or the editable element) | partial | Static page text often has no usable range → bounds empty; use the mouse position. |
| Chrome / Chromium / Electron (Slack, VS Code, Obsidian, Discord) | mostly | editable fields only | Chromium builds its AX tree lazily once an AX client talks to it; the first query right after launch can be empty, so retry once after ~100 ms. Electron apps can be forced on by setting the undocumented `AXManualAccessibility` attribute on the app element [10]. Chromium reports *paste/cut available everywhere*, so you cannot tell editable from read-only through AX actions [7]. A Chromium bug historically dropped newlines in `AXSelectedText`; PopClip added a workaround [7]. |
| Firefox | flaky | poor | Gecko disables its AX service unless an AT is detected; PopClip tells users to set `accessibility.force_disabled = -1` [7]. Falls back to ⌘C. |
| Terminal.app, iTerm2, Ghostty, Kitty | no | no | Terminals "block the Accessibility framework"; Raycast and PopClip both go to ⌘C here [8][9]. |
| Microsoft Word / Office | partial | unreliable | Treat as ⌘C-fallback apps. |
| Password fields, Secure Input | nothing | nothing | `AXSecureTextField` returns no text, and the ⌘C fallback is also blocked (next section). |
| PDF viewers (Preview yes; Acrobat no) | varies | varies | |

### Fallback: simulate ⌘C

PopClip, Raycast, Alfred and Keyboard Maestro all keep this path [7][8][9]:

1. `let before = NSPasteboard.general.changeCount`; snapshot every `pasteboardItem` and its data per type (skip promised/file-promise types, which throw or block).
2. Post ⌘C with `CGEvent(keyboardEventSource:virtualKey: 8 /* kVK_ANSI_C */, keyDown: true/false)`, flags `.maskCommand`, `post(tap: .cghidEventTap)`. Our panel must not be shown yet, or must be non-activating, so the source app stays frontmost.
3. Poll `changeCount` every ~10 ms up to ~150 ms (PopClip-class apps see 50–150 ms in heavy apps; Electron is the slow case). If it never changes: there was no selection or copy was blocked.
4. Read the string, then write the saved items back **after** the source app has finished its copy (it already has) and set `before`-style bookkeeping so your own clipboard observer ignores the blip. Declare `org.nspasteboard.TransientType` on anything you write so clipboard managers (Maccy, Raycast, Paste) skip it [11].

What breaks: the user's clipboard is briefly replaced (clipboard managers record it unless you mark it transient; PopClip has forum threads about custom data types being lost [7]); ⌘C is bound to something else in the app (Terminal with no selection does nothing, Vim-style editors may not copy); the frontmost app shows a "copied" toast; latency. And **Secure Input**: when a password field or Terminal's "Secure Keyboard Entry" has called `EnableSecureEventInput`, synthesized key events are not delivered and event taps go blind. Check `IsSecureEventInputEnabled()` first and show "Can't read a secure field" instead of posting anything.

### Permission

Both paths need **Accessibility** (TCC `kTCCServiceAccessibility`). Prompt with:

```swift
let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
let trusted = AXIsProcessTrustedWithOptions(opts)
```

The prompt appears once; afterwards only `AXIsProcessTrusted()` polling (or `com.apple.accessibility.api` distributed notification) tells you when the user flips the switch. Posting keystrokes is the "post event" right; `CGPreflightPostEventAccess()` / `CGRequestPostEventAccess()` (macOS 10.15+) exist, but an app trusted for Accessibility already has it [12][13]. **Input Monitoring** is *not* needed for anything in this app: it is required only by listen-only `CGEventTap`s and `IOHIDManager`; Apple's engineers state that Accessibility implies Input Monitoring, and `defaultTap` event taps and global key monitors use Accessibility [12][13].

## 2. Triggering

| Mechanism | Permission | Can swallow the key? | Notes |
|---|---|---|---|
| Carbon `RegisterEventHotKey` | none | yes (the app under the pointer never sees it) | Still the only modern-less API Apple never replaced; sindresorhus/KeyboardShortcuts wraps it and causes no permission dialog [14]. No modifier-only chords, no Fn-only. Works while an `NSMenu` is open. **Primary.** |
| `NSEvent.addGlobalMonitorForEvents` | Accessibility for key events; **none for mouse events** | no (observe only, asynchronous) | Apple: "you cannot modify or otherwise prevent the event…Key-related events may only be monitored if…trusted for accessibility" [15]. If untrusted, key handlers just never fire. Fine for mouse-up detection and click-outside dismissal. |
| `CGEventTap` `.defaultTap` | Accessibility | yes | Needed for modifier-only (double-tap ⌥) or modifier-click triggers. Danger: revoking Accessibility while a `.defaultTap` tap is live can hang all input until reboot on Sequoia/Tahoe (open Apple bug, FB24619068) [16]. Also disabled by the system after a slow callback (`kCGEventTapDisabledByTimeout`), must be re-enabled. |
| `CGEventTap` `.listenOnly` | Input Monitoring | no | Not worth a second permission. |
| Services menu (`NSServices` in Info.plist, `NSSendTypes` = `public.utf8-plain-text`) | none | n/a | macOS puts the selection on a private pasteboard for you; works in every app with a Services menu, including the ones where AX fails. Users can bind a key in System Settings → Keyboard → Shortcuts → Services. Writing Tools' own custom-view path is this same `NSServicesMenuRequestor` mechanism [17]. |

### PopClip-style automatic pill

PopClip shows itself on **mouse-up after a drag, double-, triple- or shift-click**, never for keyboard selections, and offers a long-press (0.5 s) to appear without a selection; users can toggle "Appear automatically" and exclude apps [7]. Implement with one global monitor for `.leftMouseDown`, `.leftMouseUp` (skip `.mouseMoved`, which fires constantly): record the down point; on up, if `distance > 4 pt` or `clickCount >= 2`, wait ~120 ms (the app needs to commit the selection and Chromium needs to update AX), read AX, and only show the pill if text came back non-empty. Do **not** use the ⌘C fallback for the automatic path (it would stomp the clipboard on every click); PopClip accepts that in those apps you must use the shortcut. Cost: global mouse monitors are cheap, but every mouse-up in a non-supporting app costs one AX round-trip (~1–5 ms, more in Electron). Suppress the pill when the mouse-up lands on our own panel, in our own app, or in excluded bundle IDs (terminals, games).

### Modifier-click (Click to Do style)

⌃⌥-click or Fn-click to start a region drag needs a `.defaultTap` so the click does not reach the app underneath. Given the tap hazards above, offer it as an opt-in secondary, implemented with an `NSEvent` *global* monitor on `.leftMouseDown` + `.leftMouseUp` with the modifier held, accepting that the first click leaks to the app (usually harmless: it just focuses a window).

**Recommendation:** primary = one hotkey (tap: text mode on the current selection; hold ≥ 300 ms or press again: region capture). Secondary = the automatic pill (off by default) and the Services entry (always on; it also gives the user a discoverable keyboard shortcut without any permission).

## 3. Capturing a screen region

### API

macOS 26 gives a dedicated screenshot API:

```swift
let cfg = SCScreenshotConfiguration()        // macOS 26
cfg.showsCursor = false
cfg.dynamicRange = .sdr                       // or .hdr / .both
cfg.displayIntent = .canonical                // colour as-authored, not the local panel's profile
let out = try await SCScreenshotManager.captureScreenshot(rect: rectInPoints, configuration: cfg)
let cg = out.sdrImage                         // SCScreenshotOutput
```

`captureScreenshot(rect:configuration:)` takes a rect "in points on the screen space…display agnostic and supports multiple displays" (top-left origin, global display space), so the overlay's drag rectangle maps directly [18][19]. The older `captureImage(in:)` (macOS 15.2) and `captureImage(contentFilter:configuration:)` (macOS 14) remain; with the latter, `SCStreamConfiguration.width/height` are **pixels** while `SCDisplay.width/height` are points, which is the classic "blurry screenshot" bug [20]. For a window under the pointer: `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)`, pick the frontmost window whose `frame` contains the pointer (ignore `windowLayer != 0`, exclude your own bundle), then `SCContentFilter(desktopIndependentWindow:)` plus `ignoreShadows`. `CGWindowListCreateImage` and `CGDisplayCreateImage` are deprecated since macOS 14 and marked unavailable in the macOS 15 SDK [21]; do not use them.

### Permission and the monthly re-prompt (macOS 15+)

Screen Recording (`kTCCServiceScreenCapture`): request with `CGRequestScreenCaptureAccess()` / check with `CGPreflightScreenCaptureAccess()`, include `NSScreenCaptureUsageDescription`. Then the Sequoia behaviour, confirmed by Apple DTS on the forums [22]: on the **second** capture after the grant, and then roughly monthly, the system shows "*Gyozaclikr is requesting to bypass the system private window picker and directly access your screen and audio…*" with **Allow For One Month** / Open System Settings. It is triggered by `SCShareableContent` queries, `SCScreenshotManager.captureImage`, `SCContentFilter` creation and the legacy CG APIs alike; one-shot screenshots are **not** exempt. The only two exits are the `com.apple.developer.persistent-content-capture` entitlement (screen-sharing products only) or `SCContentSharingPicker`, the system picker that needs no TCC grant at all but makes the user pick a window/display in Apple's UI every time [22][23]. Apple relaxed the cadence from weekly to monthly in 15 beta 6 and stopped re-prompting on every reboot [24]. For a personal build, the approval dates live in `~/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist`; Jeff Johnson's documented trick is to extend the date (needs Full Disk Access for Terminal) [25]. Plan the UX: the alert will appear mid-capture; treat an error from the capture call as "re-approval pending" and retry once.

### Overlay

One borderless `NSWindow` per `NSScreen` (`level = .screenSaver` or `.popUpMenu + 1`, `ignoresMouseEvents = false`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, `backgroundColor = .clear`, a dim `0.25` black layer), crosshair cursor via `NSCursor.crosshair.push()`, rubber band drawn in a `CALayer` with a size label, Esc cancels (`cancelOperation`), Space could switch to window mode as in ⇧⌘4. Hide the overlays and wait one `CATransaction` flush before capturing or they will be in the picture; alternatively exclude your own windows via `SCContentFilter(display:excludingWindows:)`. HiDPI: capture in native pixels (the rect is in points; the output is at display scale), keep `NSImage(cgImage:size:)` with the point size for display. Colour: `displayIntent = .canonical` for models; sRGB-convert before upload.

### Showing it in the panel

Put the `CGImage` in a SwiftUI `Image(nsImage:)` capped at ~240 pt tall with a "Retake" button; send the full-resolution image to the model. Also run Vision `RecognizeTextRequest` (macOS 15+) on the capture so the user can act on text ("copy text", "mail this") without a vision model.

## 4. The floating box next to the pointer

### Window

```swift
final class ClikrPanel: NSPanel {
  init() {
    super.init(contentRect: .zero,
               styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
               backing: .buffered, defer: true)
    isFloatingPanel = true; level = .floating          // .popUpMenu only if you must beat other floating utilities
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    hidesOnDeactivate = false; isMovableByWindowBackground = true
    becomesKeyOnlyIfNeeded = false                      // we want focus immediately
    animationBehavior = .utilityWindow
    contentView = NSHostingView(rootView: PanelRoot())
  }
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}
```

`.nonactivatingPanel` is "a panel…that does not activate the owning app" [26]. `.fullScreenAuxiliary` is what lets the panel appear over another app's full-screen Space; `.canJoinAllSpaces` keeps it on the current Space without a switch; Stage Manager leaves floating utility panels alone (Raycast/Spotlight behave the same way). Skip `.hudWindow` (dark Aqua chrome); draw your own material (`.popover`/`.hudWindow` `NSVisualEffectView` or SwiftUI `glassEffect` on 26).

### Keyboard focus without activation

Yes, typing works: `panel.makeKeyAndOrderFront(nil)` makes it the key window of *your* process while the source app stays the active app (menu bar unchanged, its windows keep "active" chrome). Caveats seen in practice: SwiftUI `@FocusState` sometimes does not land focus because the app is not active; the robust fix is `panel.makeFirstResponder(textFieldNSView)` after `orderFront`, or wrap an `NSTextView` and call `window.makeFirstResponder` yourself. The source app's text field loses its caret while you type (its window is no longer key for the session), which is expected. Never call `NSApp.activate`; on macOS 14+ activation is cooperative anyway, and once you activate you must give focus back with `NSRunningApplication(processIdentifier:).activate()`.

### Position

Anchor to the AX selection rect (converted to AppKit coordinates) 8 pt below its bottom-left; if `rect.minY − panelHeight − 8 < screen.visibleFrame.minY`, flip above. If AX gave nothing, anchor to `NSEvent.mouseLocation` (+12, −12). Choose `screen = NSScreen.screens.first { $0.frame.contains(anchor) }`, clamp x to `visibleFrame` (which already excludes the menu bar, Dock and the notch). Keep the panel on that screen while it grows; grow downward when below, upward when flipped.

### Dismissal, growth, streaming

Esc: `cancelOperation(_:)` or a key monitor in the panel. Click outside: `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown])` (no permission) plus `NSWindow.didResignKeyNotification`; also dismiss on `NSWorkspace.didActivateApplicationNotification` if the user ⌘-Tabs. Do not use `.transient` behaviour to auto-close while streaming. Input: `TextField("Ask…", text: $q, axis: .vertical).lineLimit(1...6)` and set `panel.setContentSize` from the hosting view's `fittingSize` in `onChange`. Result area: a `ScrollView` with a `Text(AttributedString(markdown:))` updated from an `AsyncThrowingStream<String>`, autoscroll pinned to bottom until the user scrolls up, buttons below: Replace · Insert below · Copy · Mail · Retry. Multi-display, Stage Manager and full-screen are covered by the collection behaviour above; the only known rough edge is a full-screen app on a *different* display than the panel's anchor, where the panel must be created on that screen's Space (ordering it front while the pointer is on that display is enough).

## 5. Acting on the source app

### Replace / insert

1. **AX set**: `AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute)` then `AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute, newText as CFString)`. Replaces the selected range; with an empty selection it inserts at the caret. Honoured by Cocoa text views, Chromium editable fields (textarea, contenteditable: Slack, Notion, Gmail in Chrome), WebKit editable; ignored (no error, or error but no change) by terminals, Word, many Qt/Java apps. Verify by re-reading `AXSelectedText`/`AXValue`; if unchanged, go to step 2.
2. **⌘V simulation**: save pasteboard items, write the new text with `org.nspasteboard.TransientType`, hide the panel, wait ~50 ms, post ⌘V (`kVK_ANSI_V = 9`, `.maskCommand`) to `.cghidEventTap`, then restore the old contents after ~300 ms. Failure modes: restoring too early makes the app paste the *old* clipboard; too late and a user who copies meanwhile loses their copy; apps with "paste and match style" bound to ⌘V variants; Secure Input blocks the keystroke entirely; the source app lost focus (the panel must be non-activating, otherwise the paste lands in Gyozaclikr). Keep the original on a "Revert" button in the panel for 30 s.
3. **Insert below**: AX set with the range collapsed to `selection.location + selection.length`, prefixed with `\n`.
4. **Copy**: plain write to `NSPasteboard.general` (no transient flag). **Open in app**: `NSWorkspace.shared.open(url)` for links, `NSSharingServicePicker` for the rest.

### Mail without a sandbox

| Route | Prompt | Attachments | Review before send | Notes |
|---|---|---|---|---|
| `NSSharingService(named: .composeEmail)` with `recipients`, `subject`, `perform(withItems: [body, fileURL])` | none | yes | yes, opens compose in the **default** mail client | Fails silently if the default mail handler is not a native app (e.g. Chrome for mailto). **Recommended default.** |
| `mailto:?subject=&body=` via `NSWorkspace` | none | no | yes | Works with Gmail-in-browser when Chrome/Safari is the mailto handler; body length limited by URL (~2–8 KB). |
| Gmail web URL `https://mail.google.com/mail/?view=cm&fs=1&to=…&su=…&body=…` | none | no | yes | Same length limits; needs the user logged in. |
| AppleScript to Mail (`NSAppleScript` / `OSAScript` / Scripting Bridge) | **Automation** per target app ("Gyozaclikr wants access to control Mail"), requires `NSAppleEventsUsageDescription`; denial → `-1743 errAEEventNotPermitted` and no second prompt (fix in Privacy & Security → Automation) [27][28] | yes | optional (`send` can go unattended) | The only route that can send without a click or pick an account/signature. Use `NSAppleScript` compiled once and run on the main thread; Scripting Bridge needs `sdp`-generated headers and breaks across Mail versions; OSAKit adds nothing here. |

### Reminders / Calendar / Contacts

EventKit on macOS 14+: `requestFullAccessToReminders`, `requestWriteOnlyAccessToEvents` (create only, cannot read back) or `requestFullAccessToEvents`, with `NSRemindersFullAccessUsageDescription`, `NSCalendarsWriteOnlyAccessUsageDescription` / `NSCalendarsFullAccessUsageDescription`; there is no read-only mode [29]. A known macOS 14.2 bug returned `granted = false` with no prompt for Reminders [30]. Contacts (to resolve "mail this to Anna"): `CNContactStore.requestAccess(for: .contacts)` + `NSContactsUsageDescription`. Alternative with zero TCC: AppleScript to Reminders/Calendar, which moves the cost to an Automation prompt instead.

## 6. Prior art and UX references

| Product | Trigger | Visual form / placement | Results | Borrow | Avoid |
|---|---|---|---|---|---|
| **ChromeOS Select to Search (Lens)** [31][32] | long-press Launcher, Launcher+Space, or screenshot key → Lens; drag a region or tap text | screen dims, rubber band; results in a right-side Google panel; "Text capture" chips (Copy, Add to Calendar) appear next to the selection on Chromebook Plus | side panel with a query field | hold-key-to-enter + drag, and action chips derived from detected dates/contacts | a side panel that reflows the desktop; our box stays at the pointer |
| **ChromeOS Quick Insert key** [33] | dedicated key (or Launcher+F) | compact menu near the caret: Help me write, emoji/GIF, recent links, Drive files, calculator, date | inserts into the focused field | insert-at-caret as the default verb when there is no selection | too many categories in one menu |
| **Windows 11 Click to Do** [34][35] | Win+click, Win+Q, Snipping Tool; Copilot+ PCs only | takes a frozen snapshot of the screen, local OCR/vision; text and images become hoverable; click a word or drag; context menu at the click point | Copy, Open with, Search web, Ask Copilot, Summarize, Bulleted list, Rewrite casual/formal; images: Copy, Save, Share, Visual search, Erase/Blur/Remove background | the single modifier+click entry; a frozen snapshot makes region capture deterministic; actions at the pointer | OCR as the only text path (we have AX); a full-screen modal just to ask about three words |
| **iOS 26 Visual Intelligence on screenshots** [36][37] | take a screenshot → "Ask" (ChatGPT) and "Image Search" buttons in the preview; draw over part of the image to narrow | buttons along the bottom of the preview; suggested actions (add event) surface automatically | chat sheet | capture → immediately show the ask field + suggestion chips; circle-to-select | nothing to copy on Mac: **macOS 26 has no Visual Intelligence**; the Mac screenshot thumbnail still offers only Markup |
| **PopClip** [7] | mouse-up after drag/double/triple/shift-click; long-press; shortcut; Services; excluded apps and an "appear automatically" switch | small dark pill of icons centred above the selection | paste back, copy, or extension-specific | the pill's anchoring, per-app exclusions, AX-first/clipboard-second reading | appearing on every selection with no way to make it quiet |
| **Raycast AI commands** [8] | hotkey → command with `{selection}`; Quick AI in the main window | large centred window, not at the text | output modes: paste, replace selection, copy, show in Raycast | explicit output modes as first-class choices | a centred window far from the text you selected |
| **Apple Writing Tools** [17] | hover affordance on a selection, context menu, Edit menu | popover anchored to the selection with chips (Proofread, Rewrite, tones, Summary, Key points, List, Table) and a "Describe your change" field | inline replacement with Original/Rewritten toggle; custom views get a panel with Copy/Share/Apply | anchored popover, free-text field, inline replace with a revert | nothing; it is the native reference for the panel |
| **Arc Max** [38] | ⌘F "Ask on Page", Shift-hover 5-second previews, command-bar ChatGPT | inline in the find bar / hover card | short answers | reuse an existing gesture instead of a new one | browser-only, so no help outside Arc |
| **Notion AI** [39] | "Ask AI" in the selection toolbar, Space on an empty line | floating window directly under the selection, dropdown of editing prompts | Replace / Insert below / Continue writing, with the draft shown before applying | the three verbs and preview-before-replace | needing the editor to be Notion |

## 7. Distribution and permissions summary

| Permission (TCC service) | Needed for | When to ask | Without it |
|---|---|---|---|
| Accessibility | AX read/set, ⌘C/⌘V simulation, key-related global monitors, `.defaultTap` | first trigger that needs text (`AXIsProcessTrustedWithOptions` with prompt) | only Services-menu input and region capture; no replace/insert |
| Screen Recording | `SCScreenshotManager`, `SCShareableContent` | first region capture (`CGRequestScreenCaptureAccess`), then the monthly "bypass the system private window picker" alert [22][24] | text-only mode; or `SCContentSharingPicker` with Apple's picker UI |
| Automation → Mail (and Reminders/Calendar if scripted) | AppleScript sending | first script run; `NSAppleEventsUsageDescription` mandatory | `NSSharingService` compose / `mailto:` still work |
| Input Monitoring | nothing in this design | never | – |
| Reminders / Calendars (full or write-only) | EventKit | first "remind me"/"add event" | AppleScript or the user's hands |
| Contacts | recipient lookup | first "mail to <name>" | type the address |
| Apple Intelligence / Foundation Models | on-device model via `SystemLanguageModel.default.availability` (macOS 26) | no TCC prompt; needs Apple Intelligence on in Settings | use the remote model only |

### Ad-hoc signing consequences

TCC identifies an app by its **designated requirement (DR)**. Apple's TN3127: "Ad hoc signed code, called Sign to Run Locally by Xcode, has a DR but it's tied to that specific version of the code…macOS can't reliably track the identity of the code. If you tweak the code and run it again, macOS repeats that prompt" [40]. Concretely, an ad-hoc DR is `cdhash H"…"`, which changes on every build, so after each update the owner would see: the app still listed and switched **on** in Privacy & Security, yet `AXIsProcessTrusted()` false and captures failing, until they remove and re-add it (the same stale-toggle symptom Rectangle documents after OS updates) [41][42]. Apple DTS confirms there is no API to migrate grants across DR changes; even a Developer-ID transfer forces a new bundle ID or `tccutil reset` [43].

**Fix: a self-signed code-signing certificate** created in Keychain Access → Certificate Assistant (type "Code Signing"), then `codesign --force --deep --options runtime -s "Gyozaclikr Dev" --identifier com.gyoza.clikr Gyozaclikr.app` (or set it as the signing identity in Xcode). The DR becomes `identifier "com.gyoza.clikr" and certificate leaf = H"<cert hash>"`, stable across rebuilds; developers report the Accessibility grant surviving repeated rebuild-reinstall cycles with a certificate, where ad-hoc differed every time [44]. Keep the bundle ID, code-signing identifier and install path (`/Applications/Gyozaclikr.app`) constant; if the certificate is ever regenerated, expect one more round of prompts. Gatekeeper is not a problem for locally built binaries (no quarantine attribute); if the owner ever downloads a build from their own CI, it will need "Open Anyway" because nothing is notarized. Keep `tccutil reset Accessibility com.gyoza.clikr` / `tccutil reset ScreenCapture com.gyoza.clikr` in a `make reset-tcc` target for the days when the toggle lies.

## Sources

1. Apple, SCScreenshotManager: https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager
2. Apple, Capturing screen content in macOS: https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos
3. Apple, SCScreenshotConfiguration (macOS 26): https://developer.apple.com/documentation/screencapturekit/scscreenshotconfiguration
4. Apple, NSWindow.StyleMask.nonactivatingPanel: https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel
5. Apple, NSEvent.addGlobalMonitorForEvents: https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:)
6. Apple, CGRequestPostEventAccess: https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess()
7. PopClip guide and forum (selection gestures, AX-first/clipboard fallback, Chromium/Firefox notes): https://www.popclip.app/guide/basics , https://forum.popclip.app/t/can-popclip-detect-editable-fields-in-browsers/3768 , https://forum.popclip.app/t/popclip-modifies-the-system-clipboard-on-every-activation/3681 , https://forum.popclip.app/t/popclip-doesnt-show-up-in-zeds-terminal/3504 , https://popclip.app/changelog
8. Raycast API, getSelectedText / Clipboard: https://developers.raycast.com/api-reference/utilities , https://developers.raycast.com/api-reference/clipboard , https://manual.raycast.com/ai
9. Alfred Universal Actions (Accessibility requirement): https://www.alfredapp.com/help/features/universal-actions/
10. Electron accessibility (AXManualAccessibility): https://www.electronjs.org/docs/latest/tutorial/accessibility
11. NSPasteboard conventions (TransientType, ConcealedType): http://nspasteboard.org
12. Apple forums, Input Monitoring vs Accessibility for event taps: https://developer.apple.com/forums/thread/122492
13. Apple forums, Accessibility permission in sandboxed app (Quinn on CGEventTap vs NSEvent monitors): https://developer.apple.com/forums/thread/707680
14. sindresorhus/KeyboardShortcuts (RegisterEventHotKey, no permission dialogs): https://github.com/sindresorhus/KeyboardShortcuts
15. See 5.
16. Apple forums, system input hang when Accessibility revoked with an active CGEventTap: https://developer.apple.com/forums/thread/844416
17. WWDC24 10168, Get started with Writing Tools: https://developer.apple.com/videos/play/wwdc2024/10168/
18. Apple, captureScreenshot(rect:configuration:): https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager/capturescreenshot(rect:configuration:completionhandler:)
19. Apple, captureImage(in:) (macOS 15.2): https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager/captureimage(in:completionhandler:)
20. Apple forums, blurry SCScreenshotManager output (points vs pixels): https://developer.apple.com/forums/thread/739593
21. MacPorts tickets on CGWindowListCreateImage unavailable in the macOS 15 SDK: https://trac.macports.org/ticket/70756 , https://trac.macports.org/ticket/71136
22. Apple forums, "bypass the system private window picker" alert, DTS answer: https://developer.apple.com/forums/thread/765103
23. TidBITS on the monthly prompt and the system picker exemption: https://tidbits.com/2024/08/19/apple-reduces-excessive-sequoia-permission-requests-shifts-to-monthly
24. 9to5Mac, Sequoia prompt moves to monthly: https://9to5mac.com/2024/08/14/macos-sequoia-screen-recording-prompt-monthly/
25. ScreenCaptureApprovals.plist workaround (Jeff Johnson / Ricci Adams): https://tinyapps.org/blog/202409180700_disable_sequoia_nag.html , https://talk.tidbits.com/t/how-to-avoid-sequoia-s-repetitive-screen-recording-permissions-prompts/28957
26. See 4.
27. Apple forums, "Not authorized to send Apple events to Mail": https://developer.apple.com/forums/thread/108815
28. Jesse Squires, Executing AppleScript in a Mac app on Mojave (NSAppleEventsUsageDescription): https://www.jessesquires.com/blog/executing-applescript-in-mac-app-on-macos-mojave/
29. Apple, Accessing the event store (EventKit access levels and keys): https://developer.apple.com/documentation/eventkit/accessing-the-event-store
30. Apple forums, Reminders permission issue on macOS 14: https://developer.apple.com/forums/thread/745752
31. 9to5Google, Chromebook Plus Select to search with Lens: https://9to5google.com/2025/06/23/chromebook-plus-lens-search/
32. Google support, Text capture on Chromebook Plus: https://support.google.com/chromebook/answer/16355371
33. 9to5Google, the Quick Insert key: https://9to5google.com/2024/10/01/chromebook-quick-insert-key/
34. Microsoft Support, Click to Do: https://support.microsoft.com/en-us/windows/click-to-do-do-more-with-what-s-on-your-screen-6848b7d5-7fb0-4c43-b08a-443d6d3f5955
35. Neowin, Click to Do available for testing: https://www.neowin.net/news/windows-11s-new-ai-feature-click-to-do-is-now-available-for-testing/
36. MacRumors, Visual Intelligence in iOS 26: https://www.macrumors.com/guide/ios-26-visual-intelligence
37. Macworld, Visual Intelligence on screenshots in iOS 26: https://www.macworld.com/article/2879052/how-to-use-visual-intelligence-to-analyze-any-screenshot-in-ios-26.html
38. Arc Max: https://arc.net/max , https://tidbits.com/2023/10/06/arc-web-browser-introduces-focused-ai-features/
39. Notion, The design thinking behind Notion AI: https://www.notion.com/blog/the-design-thinking-behind-notion-ai
40. Apple TN3127, Inside Code Signing: Requirements: https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
41. Rectangle, "not working after macOS update" (stale Accessibility toggle): https://sites.google.com/view/rectangle-app/rectangle-not-working-macos-update
42. CapSoftware/Cap issue on permissions lost with dev builds: https://github.com/CapSoftware/Cap/issues/1722
43. Apple forums, permissions after transferring to a new Developer ID (Quinn): https://developer.apple.com/forums/thread/785384
44. Field report: ad-hoc cdhash vs certificate DR, Accessibility surviving rebuilds: https://git.bdeshi.space/bdeshi/shannoncoat/releases/tag/0.0.8 ; openclaw macOS signing notes: https://docs.openclaw.ai/platforms/mac/signing
