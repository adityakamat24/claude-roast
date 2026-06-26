#!/usr/bin/env bash
# bootstrap.sh — SessionStart hook (self-healing seeder)
# Syncs plugin files to AURA_HOME, initialises state if absent, handles session mode reset.
# Emits nothing on stdout.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

in="$(cat)"
sid="$(json_str "$in" session_id)"
[ -z "$sid" ] && sid=default

ensure_home

# ── Version-gate file sync ────────────────────────────────────────────────────
PLUGIN_VER="0"
plugin_json="$AURA_PLUGIN/.claude-plugin/plugin.json"
if [ -f "$plugin_json" ]; then
  pj="$(cat "$plugin_json" 2>/dev/null)"
  v="$(json_str "$pj" version)"
  [ -n "$v" ] && PLUGIN_VER="$v"
fi

stored_ver=""
[ -f "$AURA_HOME/.version" ] && stored_ver="$(cat "$AURA_HOME/.version" 2>/dev/null)"

if [ "$stored_ver" != "$PLUGIN_VER" ]; then
  # Copy plugin artefacts into AURA_HOME (FLAT layout: statusline.sh/lib.sh/cli.sh
  # sit directly in ~/.claude/aura so the user-wired statusLine and the /claude-roast
  # skill can reference stable paths). Skip silently if a source is missing.
  # Code: always refresh on version change.
  for f in statusline.sh lib.sh cli.sh judge.sh rate-api.sh; do
    [ -f "$AURA_PLUGIN/scripts/$f" ] && cp -f "$AURA_PLUGIN/scripts/$f" "$AURA_HOME/$f" 2>/dev/null
  done
  # Data: seed ONLY if missing, so user customisations (config tuning, custom
  # verdict packs, edited rubric) survive plugin updates.
  [ -f "$AURA_HOME/config.json" ]      || cp -f "$AURA_PLUGIN/config.json"      "$AURA_HOME/config.json"      2>/dev/null
  [ -f "$AURA_HOME/ranks.tsv" ]        || cp -f "$AURA_PLUGIN/ranks.tsv"        "$AURA_HOME/ranks.tsv"        2>/dev/null
  [ -f "$AURA_HOME/judge-prompt.txt" ] || cp -f "$AURA_PLUGIN/judge-prompt.txt" "$AURA_HOME/judge-prompt.txt" 2>/dev/null
  [ -d "$AURA_HOME/verdicts" ]         || cp -rf "$AURA_PLUGIN/verdicts"        "$AURA_HOME/"                 2>/dev/null
  printf '%s' "$PLUGIN_VER" | atomic_write "$AURA_HOME/.version"
fi

# ── Initialise state if absent ────────────────────────────────────────────────
if [ ! -f "$AURA_STATE" ]; then
  start_aura="$(cfg_num start_aura 0)"
  rank_for "$start_aura"
  build_json \
    schema 1 \
    aura "$start_aura" \
    rank "$RANK_NAME" \
    face "$RANK_FACE" \
    last_delta 0 \
    last_pack "" \
    streak 0 \
    best 0 \
    worst 0 \
    turns 0 \
    mode "$(cfg_str mode lifetime)" \
    updated "$(date +%s)" \
  | atomic_write "$AURA_STATE"
  printf '' | atomic_write "$AURA_VERDICT"
fi

# ── Session mode reset (only when mode == session) ───────────────────────────
mode="$(state_get mode "$(cfg_str mode lifetime)")"
if [ "$mode" = "session" ]; then
  session_marker="$(sess_dir "$sid")/.started"
  if [ ! -f "$session_marker" ]; then
    # First SessionStart for this session — mark it, then reset aura + streak
    mkdir -p "$(sess_dir "$sid")"
    touch "$session_marker"

    start_aura="$(cfg_num start_aura 0)"
    rank_for "$start_aura"

    # Preserve cross-session history fields; only reset aura/streak
    turns="$(state_get turns 0)"
    best="$(state_get best 0)"
    worst="$(state_get worst 0)"
    last_delta="$(state_get last_delta 0)"
    last_pack="$(state_get last_pack "")"

    build_json \
      schema 1 \
      aura "$start_aura" \
      rank "$RANK_NAME" \
      face "$RANK_FACE" \
      last_delta "$last_delta" \
      last_pack "$last_pack" \
      streak 0 \
      best "$best" \
      worst "$worst" \
      turns "$turns" \
      mode "$mode" \
      updated "$(date +%s)" \
    | atomic_write "$AURA_STATE"
  fi
fi

exit 0
