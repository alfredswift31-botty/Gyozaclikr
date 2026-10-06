#!/bin/sh
# The one-shot call Gyozaclikr makes to the Claude Code CLI, by hand: prints
# the JSON the app parses. Run it on the Mac:  sh scripts/claude-cli-selftest.sh
BIN=/opt/homebrew/bin/claude
[ -x "$BIN" ] || BIN=/usr/local/bin/claude
[ -x "$BIN" ] || { echo "needs the claude CLI: neither /opt/homebrew/bin/claude nor /usr/local/bin/claude is executable"; exit 1; }
echo "binary: $BIN"
"$BIN" --strict-mcp-config --disable-slash-commands --no-session-persistence --setting-sources "" \
  --model "${CLAUDE_MODEL:-claude-sonnet-5-5}" \
  -p "You answer with one word.

Output only the result, with no preamble and no closing remark.

---

Reply with the single word OK." \
  --output-format json < /dev/null 2>/dev/null
STATUS=$?
echo
echo "exit status: $STATUS (the app reads the JSON above even when this is not 0; is_error true or subtype not success is a failure)"
exit $STATUS
