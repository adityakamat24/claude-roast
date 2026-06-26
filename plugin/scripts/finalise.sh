#!/usr/bin/env bash
# finalise.sh — Stop hook
# Reads pending + tools.log, computes TOOL/NET/PACK/VERDICT, updates state; emits nothing on stdout.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

in="$(cat)"
sid="$(json_str "$in" session_id)"
[ -z "$sid" ] && sid=default
transcript="$(json_str "$in" transcript_path)"

# stop_hook_active is a JSON boolean (unquoted), so grep directly
if printf '%s' "$in" | grep -qE '"stop_hook_active"[[:space:]]*:[[:space:]]*(true|"true")'; then
  exit 0
fi

ensure_home

# ── Read pending ──────────────────────────────────────────────────────────────
pending_file="$(sess_dir "$sid")/pending"
prompt_delta=0; prompt_pack=""; snippet=""
if [ -f "$pending_file" ]; then
  IFS='|' read -r prompt_delta prompt_pack _hash _words snippet < "$pending_file"
fi
prompt_delta="${prompt_delta:-0}"

# ── Read tools.log ────────────────────────────────────────────────────────────
tools_file="$(sess_dir "$sid")/tools.log"
n=0; edits=0; tests=0
first_tool=""; first_cmd=""
test_pat="$(cfg_str test_pattern)"

if [ -f "$tools_file" ]; then
  while IFS='|' read -r tname tsignal; do
    [ -z "$tname" ] && continue
    n=$((n + 1))
    if [ "$n" -eq 1 ]; then
      first_tool="$tname"
      first_cmd="$tsignal"
    fi
    case "$tname" in
      Edit|Write|MultiEdit|NotebookEdit)
        edits=$((edits + 1))
        ;;
      Bash)
        if [ -n "$test_pat" ] && [[ "$tsignal" =~ $test_pat ]]; then
          tests=1
        fi
        ;;
    esac
  done < "$tools_file"
fi

# Compact tool summary handed to the async model judge (judge.sh)
if [ "$n" -eq 0 ]; then
  tool_summary="no tools (a pure chat answer)"
else
  _tt="no"; [ "$tests" -eq 1 ] && _tt="yes"
  tool_summary="$n tool calls; $edits file edits; ran tests: $_tt; first: $first_tool ${first_cmd:0:48}"
fi
tool_summary="$(field_clean "$tool_summary")"

# ── Compute TOOL signal ───────────────────────────────────────────────────────
tool_delta=0; tool_pack=""
trivial_pat="$(cfg_str trivial_solo_pattern)"

if [ "$n" -eq 1 ] && [ "$first_tool" = "Bash" ] && [ -n "$trivial_pat" ] && [[ "$first_cmd" =~ $trivial_pat ]]; then
  tool_delta="$(cfg_num trivial_solo_delta -150)"
  tool_pack="trivial_solo"
elif [ "$n" -eq 1 ] && [ "$first_tool" = "Read" ]; then
  tool_delta="$(cfg_num just_a_read_delta -40)"
  tool_pack="just_a_read"
else
  if [ "$edits" -gt 0 ]; then
    edit_each="$(cfg_num edit_delta_each 30)"
    edit_max="$(cfg_num edit_delta_max 180)"
    edit_gain=$(( edits * edit_each ))
    [ "$edit_gain" -gt "$edit_max" ] && edit_gain="$edit_max"
    tool_delta=$((tool_delta + edit_gain))
    tool_pack="shipped_code"
  fi
  if [ "$tests" -eq 1 ]; then
    tool_delta=$((tool_delta + $(cfg_num test_delta 80)))
    tool_pack="shipped_tests"
  fi
  if [ "$n" -ge "$(cfg_num busy_threshold 6)" ]; then
    tool_delta=$((tool_delta + $(cfg_num busy_bonus 30)))
  fi
fi

# ── NET / PACK / VERDICT ──────────────────────────────────────────────────────
NET="$(clampi "$((prompt_delta + tool_delta))" "$(cfg_num clamp_turn_min -300)" "$(cfg_num clamp_turn_max 300)")"

if   [ -n "$tool_pack" ];   then PACK="$tool_pack"
elif [ -n "$prompt_pack" ]; then PACK="$prompt_pack"
else                              PACK="neutral"
fi

verdict="$(pick_verdict "$PACK")"
# Replace {n} placeholder with edit count for shipped_code
[ "$PACK" = "shipped_code" ] && verdict="${verdict//\{n\}/$edits}"

# ── self mode: override with the session model's own verdict marker ───────────
# The model appended  <!--aura: N | verdict -->  to its reply. Extract it from
# the transcript (instant — no model call). Freshness via a per-session marker
# count so a stale marker from a previous turn is never reused. Any miss → the
# heuristic above stands (so it can never break).
jmode="${AURA_JUDGE_MODE:-$(cfg_str judge_mode off)}"
if [ "$jmode" = "self" ] && [ -n "$transcript" ] && [ -f "$transcript" ]; then
  mc_file="$(sess_dir "$sid")/marker_count"
  prev_mc=0; [ -f "$mc_file" ] && prev_mc="$(cat "$mc_file" 2>/dev/null)"
  cur_mc="$(marker_count "$transcript")"; cur_mc="${cur_mc:-0}"
  printf '%s' "$cur_mc" | atomic_write "$mc_file"
  if [ "$cur_mc" -gt "${prev_mc:-0}" ] 2>/dev/null; then
    mk="$(marker_last "$transcript")"
    mdelta="$(marker_delta "$mk")"
    mverd="$(marker_verdict "$mk")"
    if [ -n "$mdelta" ]; then
      NET="$(clampi "$mdelta" "$(cfg_num clamp_turn_min -300)" "$(cfg_num clamp_turn_max 300)")"
      [ -n "$mverd" ] && verdict="$(field_clean "$mverd")"
      PACK="claude"
    fi
  fi
fi

# ── Load current state ────────────────────────────────────────────────────────
start_aura="$(cfg_num start_aura 0)"
aura="$(state_get aura "$start_aura")"
turns="$(state_get turns 0)"
best="$(state_get best 0)"
worst="$(state_get worst 0)"
streak="$(state_get streak 0)"
last_delta="$(state_get last_delta 0)"
mode="$(state_get mode "$(cfg_str mode lifetime)")"

# Ensure integers
aura="${aura:-0}"; turns="${turns:-0}"; best="${best:-0}"
worst="${worst:-0}"; streak="${streak:-0}"; last_delta="${last_delta:-0}"

# ── Update aura ───────────────────────────────────────────────────────────────
aura=$((aura + NET))

# ── Update streak ─────────────────────────────────────────────────────────────
if [ "$NET" -ne 0 ]; then
  if [ "$last_delta" -ne 0 ] && (( (NET > 0 && last_delta > 0) || (NET < 0 && last_delta < 0) )); then
    streak=$((streak + 1))
  else
    streak=1
  fi
else
  streak=0
fi

# ── Update best / worst ───────────────────────────────────────────────────────
[ "$NET" -gt "$best" ]  && best="$NET"
[ "$NET" -lt "$worst" ] && worst="$NET"

turns=$((turns + 1))
updated="$(date +%s)"

rank_for "$aura"

# ── Write state.json ──────────────────────────────────────────────────────────
build_json \
  schema 1 \
  aura "$aura" \
  rank "$RANK_NAME" \
  face "$RANK_FACE" \
  last_delta "$NET" \
  last_pack "$PACK" \
  streak "$streak" \
  best "$best" \
  worst "$worst" \
  turns "$turns" \
  mode "$mode" \
  updated "$updated" \
| atomic_write "$AURA_STATE"

# ── Write last_verdict.txt ────────────────────────────────────────────────────
printf '%s' "$verdict" | atomic_write "$AURA_VERDICT"

# ── Append to history.log ─────────────────────────────────────────────────────
clean_snippet="$(field_clean "$snippet")"
clean_verdict="$(field_clean "$verdict")"
printf '%s\n' "${updated}|${NET}|${PACK}|${n}|${clean_snippet}|${clean_verdict}" >> "$AURA_HISTORY"

# ── Clear session scratch ─────────────────────────────────────────────────────
: > "$pending_file"
: > "$tools_file"

# ── Hand off to the async model judge (judge.sh) when enabled ────────────────
# We always wrote the heuristic provisional above (instant + the fallback);
# judge.sh refines it a beat later. judge_input is its self-contained snapshot.
jmode="${AURA_JUDGE_MODE:-$(cfg_str judge_mode off)}"
judge_this=0
case "$jmode" in
  always) judge_this=1 ;;
  gated)
    gate="$(cfg_num judge_gate_abs 130)"; absnet="${NET#-}"
    { [ "$absnet" -lt "$gate" ] || [ "$n" -eq 0 ]; } && judge_this=1
    ;;
esac
if [ "$judge_this" -eq 1 ]; then
  smax="$(cfg_num judge_snippet_max 220)"
  {
    printf 'turn_id=%s\n' "$turns"
    printf 'hdelta=%s\n'  "$NET"
    printf 'hpack=%s\n'   "$PACK"
    printf 'ts=%s\n'      "$updated"
    printf 'snippet=%s\n' "$(field_clean "${snippet:0:$smax}")"
    printf 'tools=%s\n'   "$tool_summary"
  } | atomic_write "$(sess_dir "$sid")/judge_q/${updated}_${turns}.in"
fi

exit 0
