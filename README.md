# Gyozaclikr

A pointer-level assistant for the Mac. Select text in any app, or a region of the screen, press the shortcut, and a small box appears beside the selection. Ask for what you want: fix it, make it formal, summarise it, turn it into a list, remind me about it, send it as mail. Apple Intelligence's on-device model does the work; on macOS 27 it can see a selected picture too. Your local Ollama model is the labelled second engine for harder image questions. Nothing leaves the Mac unless you choose an engine that does, and the box says so.

Status: researched and designed; not built yet. See `docs/BRIEF.md` for the idea, `docs/PLAN.md` for the architecture and scope, `docs/DESIGN.md` for the box, and `docs/research/` for the three reports behind them.

## What it will and won't do
- Transforms of what you selected: reliable, on-device, no confirmation, undoable.
- Reminders, events, notes, mail: through Apple's own apps, always with a confirmation card.
- Questions about a picture: Live Text for the words, Apple's model on macOS 27 for a description, Ollama's Qwen3-VL when you ask for it.
- Not: identifying people, finding where to buy something, checking facts. The on-device model is a 3B-parameter transformer of text, not a source of truth, and the app treats it that way.

## Requirements
macOS 26 or later on Apple silicon with Apple Intelligence on; macOS 27 for image questions through Apple's model. Accessibility for reading selections; Screen Recording for regions.

## Development
`docs/PLAN.md` is the architecture; `docs/DESIGN.md` the contract for the box; `docs/DEVELOPMENT_LOG.md` the history. Modules: `Gyozaclikr/Core` (the shared types and protocols every module codes against), `Capture`, `Engine`, `Router`, `Actions`, `UI`, `App`. Work goes on `develop`; releases come from `main`.

CI builds twice: on GitHub's `xcode-27` preview runner with the macOS 27 SDK (the release build, with Apple's image input), and on `macos-26` with Xcode 26 (the text-only build; the image path compiles out behind `SDK_MACOS27`). Tests run on both; every box state is rendered in light and dark and printed into the log; `scripts/decode-snapshots.py <log> <dir>` recovers the images.
