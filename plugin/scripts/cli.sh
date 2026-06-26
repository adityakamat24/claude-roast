#!/usr/bin/env bash
# claude-roast cli — pure bash, no jq/python/flock.
# Subcommands: show  shame  reset [--hard]  seed  wrapper <cmd>
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# ── show ─────────────────────────────────────────────────────────────────────
cmd_show() {
  ensure_home
  local aura streak turns best worst last_delta verdict bar_str
  aura="$(state_get aura "$(cfg_num start_aura 0)")"
  streak="$(state_get streak 0)"
  turns="$(state_get turns 0)"
  best="$(state_get best 0)"
  worst="$(state_get worst 0)"
  last_delta="$(state_get last_delta 0)"
  verdict="$(read_verdict)"
  rank_for "${aura:-0}"
  bar_str="$(bar "${aura:-0}")"

  printf '\n'
  printf '%s  %saura %s%s\n' "$RANK_FACE" "$AURA_CYN" "${aura:-0}" "$AURA_RST"
  printf '  [%s]\n' "$bar_str"
  printf '  rank:    %s%s%s\n' "$AURA_YLW" "$RANK_NAME" "$AURA_RST"
  printf '  streak: %s  turns: %s\n' "${streak:-0}" "${turns:-0}"
  printf '  best:  %s%+d%s  worst: %s%+d%s\n' \
    "$AURA_GRN" "${best:-0}" "$AURA_RST" \
    "$AURA_RED" "${worst:-0}" "$AURA_RST"
  if [ -n "$verdict" ]; then
    printf '  last:  %s%s%s (%s%+d%s)\n' \
      "$AURA_DIM" "$verdict" "$AURA_RST" \
      "$AURA_MAG" "${last_delta:-0}" "$AURA_RST"
  fi
  printf '\n'
}

# ── shame ────────────────────────────────────────────────────────────────────
cmd_shame() {
  ensure_home
  if [ ! -f "$AURA_HISTORY" ]; then
    printf 'No history yet — keep prompting!\n'
    return 0
  fi
  local n; n="$(cfg_num shame_cap 5)"
  printf '\n%s== Hall of Shame ==%s\n\n' "$AURA_RED" "$AURA_RST"
  local count=0 ts delta pack tools snippet verdict
  while IFS='|' read -r ts delta pack tools snippet verdict; do
    printf '  %s%-5s%s  %-28s  %s(%s)%s\n' \
      "$AURA_RED" "$delta" "$AURA_RST" \
      "${verdict:-(no verdict)}" \
      "$AURA_DIM" "${snippet:-(no snippet)}" "$AURA_RST"
    count=$((count + 1))
  done < <(sort -t'|' -k2 -n "$AURA_HISTORY" | head -"$n")
  [ "$count" -eq 0 ] && printf '  No shame on record yet — you'\''re doing alright!\n'
  printf '\n'
}

# ── reset ────────────────────────────────────────────────────────────────────
cmd_reset() {
  ensure_home
  local start_aura; start_aura="$(cfg_num start_aura 0)"
  local mode; mode="$(state_get mode "$(cfg_str mode lifetime)")"
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
    mode "$mode" \
    updated "$(date +%s)" \
    | atomic_write "$AURA_STATE"
  printf '' | atomic_write "$AURA_VERDICT"
  if [ "${1:-}" = "--hard" ]; then
    : > "$AURA_HISTORY"
    printf 'State and history reset to zero.\n'
  else
    printf 'State reset to zero (history preserved; use reset --hard to also wipe history).\n'
  fi
}

# ── seed ─────────────────────────────────────────────────────────────────────
cmd_seed() {
  ensure_home
  local plugin="$AURA_PLUGIN"

  # copy runtime files from the plugin into AURA_HOME
  if [ -f "$plugin/scripts/statusline.sh" ]; then
    cp -f "$plugin/scripts/statusline.sh" "$AURA_HOME/statusline.sh"
    chmod +x "$AURA_HOME/statusline.sh" 2>/dev/null
  else
    printf 'warn: %s/scripts/statusline.sh not found (skipped)\n' "$plugin" >&2
  fi
  cp -f  "$plugin/scripts/lib.sh"  "$AURA_HOME/lib.sh"
  cp -f  "$plugin/scripts/cli.sh"  "$AURA_HOME/cli.sh"
  cp -f  "$plugin/config.json"     "$AURA_HOME/config.json"
  cp -f  "$plugin/ranks.tsv"       "$AURA_HOME/ranks.tsv"
  cp -rf "$plugin/verdicts"        "$AURA_HOME/verdicts"
  chmod +x "$AURA_HOME/cli.sh" 2>/dev/null

  # create initial state.json if missing
  if [ ! -f "$AURA_STATE" ]; then
    local start_aura; start_aura="$(cfg_num start_aura 0)"
    local mode; mode="$(cfg_str mode lifetime)"
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
      mode "$mode" \
      updated "$(date +%s)" \
      | atomic_write "$AURA_STATE"
    printf 'Created initial state.json\n'
  fi

  printf 'Seeded to: %s\n' "$AURA_HOME"
  printf '  %-22s -> %s/statusline.sh\n' "statusline.sh"  "$AURA_HOME"
  printf '  %-22s -> %s/lib.sh\n'        "lib.sh"         "$AURA_HOME"
  printf '  %-22s -> %s/cli.sh\n'        "cli.sh"         "$AURA_HOME"
  printf '  %-22s -> %s/config.json\n'   "config.json"    "$AURA_HOME"
  printf '  %-22s -> %s/ranks.tsv\n'     "ranks.tsv"      "$AURA_HOME"
  printf '  %-22s -> %s/verdicts/\n'     "verdicts/"      "$AURA_HOME"
}

# ── wrapper ──────────────────────────────────────────────────────────────────
cmd_wrapper() {
  local existing_cmd="${1:-}"
  if [ -z "$existing_cmd" ]; then
    printf 'Usage: cli.sh wrapper "<existing_command>"\n' >&2
    exit 1
  fi
  ensure_home
  local out="$AURA_HOME/statusline-wrapper.sh"
  # NOTE: WRAPPER_EOF is unquoted so ${existing_cmd} and ${AURA_HOME} expand
  # here; \$var in the body becomes literal $var in the generated script.
  cat > "$out" <<WRAPPER_EOF
#!/usr/bin/env bash
in="\$(cat)"
a="\$(printf '%s' "\$in" | ${existing_cmd})"
b="\$(printf '%s' "\$in" | bash "${AURA_HOME}/statusline.sh" --segment)"
printf '%s  %s' "\$a" "\$b"
WRAPPER_EOF
  chmod +x "$out"
  printf 'Wrapper written to: %s\n' "$out"
  printf '\nUpdate statusLine in ~/.claude/settings.json to:\n'
  printf '  "statusLine": {"type":"command","command":"bash \\"%s/statusline-wrapper.sh\\""}\n' "$AURA_HOME"
  printf '\n(Back up settings.json before editing.)\n'
}

# ── dispatch ─────────────────────────────────────────────────────────────────
case "${1:-show}" in
  show)    cmd_show ;;
  shame)   cmd_shame ;;
  reset)   cmd_reset "${2:-}" ;;
  seed)    cmd_seed ;;
  wrapper) cmd_wrapper "${2:-}" ;;
  *)
    printf 'Usage: cli.sh [show|shame|reset [--hard]|seed|wrapper <cmd>]\n' >&2
    exit 1
    ;;
esac
exit 0
