# Gyozaclikr

A pointer-level assistant for the Mac. Select text in any app, or a region of the screen, press the shortcut, and a small box appears beside the selection. Ask for what you want: fix it, make it formal, summarise it, turn it into a list, remind me about it, send it as mail. Apple Intelligence's on-device model does the work by default; on macOS 27 it can see a selected picture too. Your local Ollama model is the labelled second engine for harder image questions, and Claude, through the Claude Code CLI signed in on your Mac, is the third. You pick the engine in the box. Nothing leaves the Mac unless you choose an engine that does, and the box says so.

Status: 1.0 built and released from CI; not yet verified on a Mac. See `docs/BRIEF.md` for the idea, `docs/PLAN.md` for the architecture and scope, `docs/DESIGN.md` for the box, and `docs/research/` for the three reports behind them.

## What it will and won't do
- Transforms of what you selected: reliable, on-device, no confirmation, undoable.
- Reminders, events, notes, mail: through Apple's own apps, always with a confirmation card.
- Questions about a picture: Live Text for the words, Apple's model on macOS 27 for a description, Ollama's Qwen3-VL when you ask for it.
- Not: identifying people, finding where to buy something, checking facts. The on-device model is a 3B-parameter transformer of text, not a source of truth, and the app treats it that way.

## How to use it
1. Select text in any app (or nothing, to define the word under the pointer).
2. Press **⌃Space**. The box appears under the selection. Hold ⌃Space instead to draw a region of the screen.
3. Press ⌘1–⌘8 for a chip (Fix, Shorter, Formal, Casual, Summarise, List, Reply, Remind) or type what you want and press Enter.
4. Replace puts the answer back where the text came from; Copy, Insert below and Send… are next to it. Replace leads when the app's text field is one macOS can write into directly; in other apps (Electron, web fields) it comes after Copy and pastes with ⌘V, and the line under the buttons says which happened. Drag the box anywhere by its background, resize it by the corner grip or an edge; the × or Esc closes it.
5. Keep typing: each question and answer stacks in the box as a conversation, and a follow-up (“make it shorter”, “now in French”) knows what came before.
6. The engine row (under the chips, or under an answer) is a menu: Apple Intelligence, Ollama or Claude. The choice applies to the next request and sticks; Settings › Engines has the same choice. Type `/apple`, `/local` or `/claude` first to force one request.

### Claude
Claude runs through the Claude Code CLI that is installed and signed in on your Mac, once per request, so calls count against your Claude plan; no API key. The app looks for `/opt/homebrew/bin/claude`, then `/usr/local/bin/claude`. To check it on your Mac: Settings › Engines › Claude › **Test** makes one real call and shows the result and the time, or run the same call by hand:

```sh
sh scripts/claude-cli-selftest.sh
```

If the result says it failed to authenticate, run `claude` in Terminal and use `/login`. The model is `claude-sonnet-5-5` unless you type another id in Settings. "Let Claude search the web" (off by default) lets it look up current facts such as a price; a search adds ten to twenty seconds and spends more of your plan.

A small olive gyoza floats beside the pointer while the app is running, so you can see it is alive; it steps aside while the box is open. The menu-bar gyoza shows the shortcut, the last answer, history, the engines' state and the permissions. If ⌃Space is held by macOS (it switches keyboard languages when more than one is on), the app falls back to ⌃⌥Space and Settings › General says so. Record any combination you like there under Shortcut: click the field and press the keys. § or a function key works on its own; a bare letter is refused, since it would steal typing everywhere.

## Versions
- **1.1.4** (7 Oct 2026): the shortcut can be § (or a function key) on its own; the Settings section is headed Shortcut and says what it takes.
- **1.1.3** (6 Oct 2026): a switch lets Claude search the web for current facts (confirmed on the owner's Mac); off, it is told it has no tools, so it never reports a denied search as its answer. A thanks in the thread gets a few words, not the last answer again.
- **1.1.2** (6 Oct 2026): the ⌘V behind Replace is posted into the source app's process, not at the system level where the box itself held the keyboard. Replace and Insert below confirmed in an Electron app.
- **1.1.1** (6 Oct 2026): Replace and Insert below are offered for any text read from an app, by ⌘V where Accessibility cannot write (Electron, web fields); the outcome line says which path ran.
- **1.1** (6 Oct 2026): Claude as the third engine, through the Claude Code CLI signed in on the Mac (no API key); the engine row is a picker, the choice sticks, and `/apple`, `/local`, `/claude` force one request. Confirmed on the owner's Mac.
- **1.0.12** (6 Oct 2026): the box can be resized by its corner grip or any edge and keeps that size (⋯ › Automatic size undoes it); fence marks never leak into an answer; follow-ups are told not to repeat an earlier answer.
- **1.0.11** (6 Oct 2026): questions the selection does not answer are answered from the model's general knowledge, prefixed “From general knowledge:”; rewrites still stay inside the selection.
- **1.0.10** (6 Oct 2026): the box actually drags (1.0.9's drag never started through the SwiftUI host); Send… composes in whatever handles mailto:, Gmail in Chrome included, instead of only activating it. Both confirmed on the owner's Mac. If Send… opens Chrome without a compose window, allow Gmail as Chrome's mailto handler once (the diamond icon in Gmail's address bar).
- **1.0.9** (6 Oct 2026): the box keeps a running conversation (follow-ups carry the earlier turns); it can be dragged anywhere, stays until its × (or Esc) closes it, and no longer vanishes on a click elsewhere; image descriptions from Apple's model say what a picture is for when that is clear; an Ask Ollama button under them gives the deeper read.
- **1.0.8** (6 Oct 2026): the box's height follows its content exactly; the action row is no longer cut off.
- **1.0.7** (6 Oct 2026): the box widens with its answer instead of clipping it.
- **1.0.6** (6 Oct 2026): the selection is read before the box opens; the box had been taking keyboard focus first and reading itself.
- **1.0.5** (6 Oct 2026): the first press asks for Accessibility; a request over nothing selected is refused with the reason instead of going to the model.
- **1.0.4** (6 Oct 2026): the box appears without a fade; Settings › Engines shows what the box did on the last press, for diagnosis.
- **1.0.3** (6 Oct 2026): a small olive gyoza floats beside the pointer while the app runs (Settings › General turns it off).
- **1.0.2** (6 Oct 2026): the first hold of the shortcut crashed the app in the region overlay (an AppKit initialiser calling back into an unimplemented one); fixed. A press now counts as a hold after half a second, not 300 ms.
- **1.0.1** (6 Oct 2026): Settings opens (it did not from a menu-bar agent); the shortcut falls back when macOS holds ⌃Space, and Settings says so.
- **1.0** (6 Oct 2026): first release. Hot key and Services entry, selection reading with a ⌘C fallback, region capture with Live Text, the box with eight chips and free text, Apple's on-device model (text; images on macOS 27), Ollama as the labelled second engine, reminders, events, notes, mail compose, search, Shortcuts, dictionary, history, Engines and Permissions panes.

## Install
Download `Gyozaclikr.zip` from the latest release, unzip, move to Applications, open. The first launch is refused by Gatekeeper (the app is not notarized): System Settings › Privacy & Security › Open Anyway. Grant Accessibility when asked; Screen Recording is asked on the first region capture. To keep those grants across updates, run `scripts/resign.sh` once with your own certificate (see the script).

## Requirements
macOS 26 or later on Apple silicon with Apple Intelligence on; macOS 27 for image questions through Apple's model. Accessibility for reading selections; Screen Recording for regions.

## Development
`docs/PLAN.md` is the architecture; `docs/DESIGN.md` the contract for the box; `docs/DEVELOPMENT_LOG.md` the history. Modules: `Gyozaclikr/Core` (the shared types and protocols every module codes against), `Capture`, `Engine`, `Router`, `Actions`, `UI`, `App`. Work goes on `develop`; releases come from `main`.

CI builds twice: on GitHub's `xcode-27` preview runner with the macOS 27 SDK (the release build, with Apple's image input), and on `macos-26` with Xcode 26 (the text-only build; the image path compiles out behind `SDK_MACOS27`). Tests run on both; every box state is rendered in light and dark and printed into the log; `scripts/decode-snapshots.py <log> <dir>` recovers the images.
