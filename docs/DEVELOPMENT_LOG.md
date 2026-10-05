# Gyozaclikr development log

A pointer-level assistant for the Mac: select, summon, ask, act. On-device.

## Releases

| Version | Date | Release |
|---|---|---|
| 1.0 | 2026-10-06 | [v1.0](https://github.com/alfredswift31-botty/Gyozaclikr/releases/tag/v1.0) |
| 1.0.1 | 2026-10-06 | [v1.0.1](https://github.com/alfredswift31-botty/Gyozaclikr/releases/tag/v1.0.1) |

## Research and design (5 Oct 2026)
Three agents researched in parallel: Apple's APIs, the system-integration layer, and the product and the box. Reports in `docs/research/`. The decisive finding: Apple's on-device Foundation Model takes images on macOS 27 (`Attachment`), verified against Apple's documentation data, so the app leads with Apple Intelligence for pictures and keeps the owner's Qwen3-VL via Ollama as the labelled second engine. Decisions: a deterministic chip row plus a pre-router before any free-text goes to the model; quote verification on every extraction (GyozaYap measured the model inventing items); confirmation cards for anything outward; a self-signed certificate rather than ad-hoc signing, because macOS ties Accessibility and Screen Recording grants to the designated requirement. "Who is this person" and "where can I buy it" are refused by design.

## 1.0: the build (5 Oct 2026)
Scaffold: the project file cloned from GyozaVitals (synchronized folders, Swift 5 mode, default MainActor isolation, macOS 26 minimum), `Core/Model.swift` as the contract between modules, the theme shared with the suite plus the box's tokens, Info.plist with every usage string and the Services entry, the apple-events entitlement, CI on GitHub's `xcode-27` preview runner (macOS 27 SDK; `SDK_MACOS27` set by an SDK-conditional build setting) and on `macos-26` for the text-only build. Four agents then built Capture, Engine, Router + Actions and UI against the contract, each with tests, on their own branches; the coordinator wired them.

**What the agents built and CI proved** (develop green on both runners, 89f8520). Capture: Carbon hot key (tap vs hold through a tested state machine), Accessibility read with a Chromium retry and a ⌘C fallback behind a Secure Input check, region capture with ScreenCaptureKit and a per-display overlay, Vision OCR (proved on the macOS 26 runner: "Gyozaclikr reads 42 words" came back; the macOS 27 preview runner's Vision returns `unknownError`, an anomaly of that image), the Services entry, the two capture permissions. Engine: Apple's model with permissive guardrails for transforms, token budgets and map-reduce chunking, quote-verified extraction, the four tools with a one-outward-action policy, and the macOS 27 image path (`Attachment(cgImage)` inside a `@Generable` description, compiled against the macOS 27.2 SDK on the `xcode-27` runner, compiled out on Xcode 26); Ollama streaming with images; the probe. Router: 68 routing rows including the eight research transcripts, refusals for people, shopping and fact-checking, a relative-date grammar with NSDataDetector as fallback (the detector returns nothing for "next week" or "in 2 hours", measured). Actions: AX replace with a ⌘V fallback, mail compose through the sharing service, EventKit, a Notes AppleScript, Shortcuts, search, the dictionary (a real definition came back on CI), history. UI: the box in nine states, the status item, Settings; 13 snapshot pairs rendered and reviewed against docs/DESIGN.md.

**Integration found two things no module could.** Both Capture and Actions had declared a `PasteboardSnapshot` (the brief had allowed the duplicate; the compiler did not), and the scaffold's Info.plist used a reminders usage key that does not exist: macOS has no add-only level for reminders, so the app asks for full access and the key is `NSRemindersFullAccessUsageDescription`.

**Measured on the runners, to be measured on the Mac next.** Apple Intelligence is unavailable on every GitHub runner (`deviceNotEligible`, even the arm64 preview), so every live-model path, the image probe, `contextSize` and `variant` are unproven until the owner's Engines pane reports them. The first screenshot to ask for is that pane.

**Signing.** 1.0 ships ad-hoc signed from CI, so each update will drop the Accessibility and Screen Recording grants until re-granted. `scripts/resign.sh` re-signs a downloaded build with a self-signed certificate, which keeps the grants; CI signing from a certificate held as a secret is the first 1.0.x change once the owner has made one.

## 1.0.1: the first launch (6 Oct 2026)
The owner opened 1.0, clicked Settings… in the menu, and nothing appeared. The coordinator sent SwiftUI's `showSettingsWindow:` selector, which a menu-bar agent with no key window does not answer on current macOS. Settings is now a window the app owns (`SettingsWindow`, an `NSHostingController` of the same view). Second finding, from reasoning rather than the Mac: the default ⌃Space is macOS's own input-source switch when two keyboard languages are enabled, and Carbon refuses a taken combination silently, so the app would summon nothing and say nothing. Registration now falls back to ⌃⌥Space, then ⇧⌘Space, and the General tab says in red when the saved combination is held by the system. The README gained a "How to use it" section; the first thing a new user asked was how.

## Where things stand (6 Oct 2026)
Built in one night from the research: a scaffold, four module agents on their own branches, a coordinator. Nothing has run on a Mac yet. The order of verification: the Engines pane (does Apple's model take an image on this M4?), the box on a text selection in TextEdit (Replace), the same in Safari and a Chromium app, a region capture (the Screen Recording prompt), one chip, one free-text rewrite, one reminder with a date (the confirmation card and the EventKit prompt), one `/local` image question against Ollama.

