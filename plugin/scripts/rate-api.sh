#!/usr/bin/env bash
# rate-api.sh — OPTIONAL lean rater for claude-roast. Drop-in for `claude -p`:
#     rate-api.sh -p --model <haiku|sonnet|opus|id> "<prompt>"
# Calls the Anthropic Messages API directly with a TINY system prompt and a small
# max_tokens cap — far fewer tokens + much faster than `claude -p` (which loads the
# whole Claude Code agent). Prints the model's text to stdout (the {"d","v"} line).
#
# Requirements (all OPT-IN; the default `claude -p` path needs none of these):
#   - ANTHROPIC_API_KEY in the environment (your own key)
#   - python (used for the request + JSON parsing; no jq/curl needed)
# Exits non-zero / empty on any problem so judge.sh cleanly falls back to heuristics.

key="${ANTHROPIC_API_KEY:-}"
[ -z "$key" ] && exit 3
command -v python >/dev/null 2>&1 || exit 3

model="claude-haiku-4-5-20251001"
prompt=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p|--print) ;;
    --model)
      shift
      case "${1:-}" in
        haiku)  model="claude-haiku-4-5-20251001" ;;
        sonnet) model="claude-sonnet-4-6" ;;
        opus)   model="claude-opus-4-8" ;;
        "")     ;;
        *)      model="$1" ;;
      esac
      ;;
    *) prompt="$1" ;;
  esac
  shift
done
[ -z "$prompt" ] && exit 3

ANTHROPIC_API_KEY="$key" MODEL="$model" PROMPT="$prompt" python - <<'PY' 2>/dev/null
import json, os, sys, urllib.request
key = os.environ["ANTHROPIC_API_KEY"]; model = os.environ["MODEL"]; prompt = os.environ["PROMPT"]
body = json.dumps({
    "model": model,
    "max_tokens": 80,
    "system": "You are a terse rater. Output only the single line of JSON the user asks for, nothing else.",
    "messages": [{"role": "user", "content": prompt}],
}).encode()
req = urllib.request.Request(
    "https://api.anthropic.com/v1/messages",
    data=body,
    headers={"x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json"},
)
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.load(r)
    sys.stdout.write(data["content"][0]["text"])
except Exception:
    sys.exit(4)
PY
