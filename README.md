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
