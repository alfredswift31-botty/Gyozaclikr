# Gyozaclikr

A pointer-level assistant for the Mac. Select text in any app, or a region of the screen, press the shortcut, and a small box appears beside the selection. Ask for what you want: fix it, make it formal, summarise it, turn it into a list, remind me about it, send it as mail. Apple Intelligence's on-device model does the work; on macOS 27 it can see a selected picture too. Your local Ollama model is the labelled second engine for harder image questions. Nothing leaves the Mac unless you choose an engine that does, and the box says so.

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
4. Replace puts the answer back where the text came from; Copy, Insert below and Send… are next to it. Drag the box anywhere by its background; the × or Esc closes it.
5. Keep typing: each question and answer stacks in the box as a conversation, and a follow-up (“make it shorter”, “now in French”) knows what came before.

A small olive gyoza floats beside the pointer while the app is running, so you can see it is alive; it steps aside while the box is open. The menu-bar gyoza shows the shortcut, the last answer, history, the engines' state and the permissions. If ⌃Space is held by macOS (it switches keyboard languages when more than one is on), the app falls back to ⌃⌥Space and Settings › General says so; record any combination you like there.

## Versions
- **1.0.10** (6 Oct 2026): the box actually drags (1.0.9's drag never started through the SwiftUI host); Send… composes in whatever handles mailto:, Gmail in Chrome included, instead of only activating it.
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
