#!/usr/bin/env bash
# claude-roast — statusline renderer.
# Reads aura state from $AURA_HOME and prints a styled statusline chunk.
# No trailing newline. Always exits 0. No external deps beyond coreutils.
#
# Usage:
#   statusline.sh              → full line (wide or narrow per $COLUMNS)
#   statusline.sh --segment    → compact chunk for appending to existing statusline
#   statusline.sh --narrow     → force narrow variant of the full line
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Consume stdin once (session JSON — injected by Claude Code; unused here)
in="$(cat)"

# ── Parse mode ────────────────────────────────────────────────────────────────
mode="full"
case "${1:-}" in
  --segment) mode="segment"      ;;
  --narrow)  mode="narrow-full"  ;;
esac

# ── Read state — guard every read, worst case falls back to neutral ────────────
aura="$(state_get aura "$(cfg_num start_aura 0)")"
[[ "$aura" =~ ^-?[0-9]+$ ]] || aura=0

rank="$(state_get rank)"
face="$(state_get face)"
last_delta="$(state_get last_delta 0)"
[[ "$last_delta" =~ ^-?[0-9]+$ ]] || last_delta=0

verdict="$(read_verdict)"

# If rank/face absent (first run or corrupt state), derive from rank_for
if [ -z "$rank" ] || [ -z "$face" ]; then
  rank_for "$aura"
  rank="$RANK_NAME"
  face="$RANK_FACE"
fi

# First-run flag: no state file → verdict tail shows — instead of empty
first_run=0
[ -f "$AURA_STATE" ] || first_run=1

# ── Build display tokens ───────────────────────────────────────────────────────
# Delta: green +N / red -N / dim 0; always shows explicit sign for nonzero
if [ "$last_delta" -gt 0 ] 2>/dev/null; then
  delta_tok="${AURA_GRN}+${last_delta}${AURA_RST}"
elif [ "$last_delta" -lt 0 ] 2>/dev/null; then
  delta_tok="${AURA_RED}${last_delta}${AURA_RST}"
else
  delta_tok="${AURA_DIM}0${AURA_RST}"
fi

# Bar (computed from config-driven floor/ceil/width)
bar_str="$(bar "$aura")"

# Verdict: dim text; fall back to em-dash on first run or empty verdict
if [ "$first_run" -eq 1 ] || [ -z "$verdict" ]; then
  verdict_display="${AURA_DIM}—${AURA_RST}"
else
  verdict_display="${AURA_DIM}${verdict}${AURA_RST}"
fi

# Rank: cyan
rank_display="${AURA_CYN}${rank}${AURA_RST}"

# ── Narrow detection ──────────────────────────────────────────────────────────
narrow_cols_val="$(cfg_num narrow_cols 80)"
is_narrow=0
if [ "$mode" = "narrow-full" ]; then
  is_narrow=1
elif [ -n "${COLUMNS:-}" ] && [ "$COLUMNS" -lt "$narrow_cols_val" ] 2>/dev/null; then
  is_narrow=1
fi

# ── Render ────────────────────────────────────────────────────────────────────
case "$mode" in
  segment)
    # Compact chunk — no verdict tail; narrow drops bar
    if [ "$is_narrow" -eq 1 ]; then
      printf '%s' "${face} aura ${aura} ${delta_tok}"
    else
      printf '%s' "${face} aura ${aura} [${bar_str}] ${delta_tok}"
    fi
    ;;
  *)
    # Full line (wide) or narrow-full; narrow drops bar and last:/verdict tail
    if [ "$is_narrow" -eq 1 ]; then
      printf '%s' "${face} aura ${aura} ${rank_display} ${delta_tok}"
    else
      printf '%s' "${face} aura ${aura} [${bar_str}] ${rank_display}  last: ${verdict_display} ${delta_tok}"
    fi
    ;;
esac

exit 0
