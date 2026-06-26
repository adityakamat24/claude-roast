#!/usr/bin/env bash
# log-tool.sh — PostToolUse hook
# Appends one tool|signal line to the session's tools.log; emits nothing on stdout.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

in="$(cat)"
sid="$(json_str "$in" session_id)"
[ -z "$sid" ] && sid=default

ensure_home
mkdir -p "$(sess_dir "$sid")"

tool="$(json_str "$in" tool_name)"

# Build signal depending on tool type (CONTRACT: unique inner keys command / file_path)
case "$tool" in
  Bash)
    cmd="$(json_str "$in" command)"
    signal="$(field_clean "$(lower "$cmd")")"
    ;;
  Write|Edit|MultiEdit|NotebookEdit)
    signal="$(json_str "$in" file_path)"
    ;;
  *)
    signal=""
    ;;
esac

printf '%s\n' "${tool}|${signal}" >> "$(sess_dir "$sid")/tools.log"

exit 0
