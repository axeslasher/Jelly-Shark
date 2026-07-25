#!/bin/sh
# PostToolUse hook: swiftformat the single Swift file Claude just wrote, so
# formatting is never a separate step or a surprise in CI.
#
# Wired up in .claude/settings.json (PostToolUse, matcher "Edit|Write"). Reads
# the tool payload as JSON on stdin.
#
# Mirrors the version gate in .githooks/pre-commit: formatting with a
# swiftformat other than the pinned one would produce output CI then rejects,
# so an unpinned or missing binary skips silently rather than guessing. Every
# exit is 0 — a formatter must never fail the edit that triggered it.

REQUIRED_VERSION="0.62.1"

FILE=$(jq -r '.tool_input.file_path // empty')
[ -n "$FILE" ] || exit 0

# Quoted throughout: this repo's paths contain spaces ("Jelly Shark/Jelly Shark").
case "$FILE" in
*.swift) ;;
*) exit 0 ;;
esac
[ -f "$FILE" ] || exit 0

command -v swiftformat >/dev/null 2>&1 || exit 0
[ "$(swiftformat --version)" = "$REQUIRED_VERSION" ] || exit 0

# swiftformat finds .swiftformat by walking up from the file, so the pinned
# rule set and --exclude apply here exactly as they do in `make format`.
swiftformat --quiet "$FILE" >/dev/null 2>&1 || true
exit 0
