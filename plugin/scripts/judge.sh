#!/usr/bin/env bash
# judge.sh — async Stop hook. Asks a cheap model to "naturally" rate the turn and
# REFINES the heuristic provisional that finalise.sh already wrote. Runs in the
# background (async hook) so the ~seconds of model latency never block a turn.
# On ANY failure (no rater, offline, timeout, unparseable) it leaves the
# heuristic provisional untouched. Emits nothing on stdout.
JUDGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$JUDGE_DIR/lib.sh"

mode="${AURA_JUDGE_MODE:-$(cfg_str judge_mode off)}"
[ "$mode" = "off" ] && exit 0

# session id from stdin (Stop event) or optional $1 (tests)
in="$(cat 2>/dev/null)"
sid="$(json_str "$in" session_id)"
[ -z "$sid" ] && sid="${1:-default}"

sd="$(sess_dir "$sid")"
qdir="$sd/judge_q"

# finalise enqueues one snapshot per judged turn; wait briefly for one to appear.
poll="$(cfg_num judge_poll_ms 1500)"; waited=0
while [ -z "$(ls -1 "$qdir"/*.in 2>/dev/null | head -1)" ]; do
  sleep 0.1 2>/dev/null || sleep 1
  waited=$((waited + 100))
  [ "$waited" -ge "$poll" ] && exit 0
done
# Claim the oldest queued snapshot atomically (mv); if a sibling judge took it, bail.
f="$(ls -1tr "$qdir"/*.in 2>/dev/null | head -1)"
[ -z "$f" ] && exit 0
ji="$f.busy"
mv "$f" "$ji" 2>/dev/null || exit 0

# ── Read the turn snapshot (key=value lines) ─────────────────────────────────
turn_id=0; hdelta=0; hpack=""; ts=0; snippet=""; tools=""
while IFS='=' read -r k v; do
  case "$k" in
    turn_id) turn_id="$v" ;;
    hdelta)  hdelta="$v" ;;
    hpack)   hpack="$v" ;;
    ts)      ts="$v" ;;
    snippet) snippet="$v" ;;
    tools)   tools="$v" ;;
  esac
done < "$ji"
rm -f "$ji"
hdelta="${hdelta:-0}"

# ── Build the prompt from the editable rubric ────────────────────────────────
tmpl="$(cat "$(judge_prompt_path)" 2>/dev/null)"
[ -z "$tmpl" ] && exit 0
prompt="${tmpl//\{snippet\}/$snippet}"
prompt="${prompt//\{tools\}/$tools}"

# ── Call the (pluggable) rater ───────────────────────────────────────────────
jcmd="${AURA_JUDGE_CMD:-$(cfg_str judge_cmd auto)}"
jmodel="$(cfg_str judge_model haiku)"
jto="$(cfg_num judge_timeout 60)"
# Resolve the rater. "auto" → lean direct API when ANTHROPIC_API_KEY is set
# (rate-api.sh: fast, ~170 tokens), else the no-setup `claude -p`. A custom
# judge_cmd (or AURA_JUDGE_CMD) is used verbatim — e.g. a local Ollama wrapper.
if [ "$jcmd" = "auto" ]; then
  if [ -n "$ANTHROPIC_API_KEY" ] && [ -f "$JUDGE_DIR/rate-api.sh" ] && command -v python >/dev/null 2>&1; then
    rater=(bash "$JUDGE_DIR/rate-api.sh")
  else
    rater=(claude)
  fi
elif [ "$jcmd" = "claude" ]; then
  rater=(claude)
else
  rater=("$jcmd")
fi
if [ "${rater[0]}" != "bash" ]; then
  command -v "${rater[0]}" >/dev/null 2>&1 || exit 0
fi
raw="$(timeout "$jto" "${rater[@]}" -p --model "$jmodel" "$prompt" 2>/dev/null)"
[ -z "$raw" ] && exit 0

# ── Parse {"d":int,"v":"..."} ────────────────────────────────────────────────
d="$(json_num "$raw" d)"
v="$(json_str "$raw" v)"
case "$d" in ''|*[!0-9-]*) d="" ;; esac      # require a clean integer
[ -z "$d" ] && exit 0                          # parse failed → keep heuristic
d="$(clampi "$d" "$(cfg_num clamp_turn_min -300)" "$(cfg_num clamp_turn_max 300)")"
[ -z "$v" ] && v="$(pick_verdict "${hpack:-neutral}")"
v="$(field_clean "$v")"

# ── Apply under lock: correction = model_delta - heuristic_delta ─────────────
# (finalise already added hdelta to aura; we add the difference so the net is
#  the model's delta, and concurrent turns' corrections still compose.)
correction=$((d - hdelta))
lock="$AURA_HOME/.judge.lock"
lock_acquire "$lock" 4000 || exit 0

cur_aura="$(state_get aura 0)";  cur_aura="${cur_aura:-0}"
cur_turns="$(state_get turns 0)"; cur_turns="${cur_turns:-0}"
streak="$(state_get streak 0)";  best="$(state_get best 0)";  worst="$(state_get worst 0)"
mode_s="$(state_get mode "$(cfg_str mode lifetime)")"
new_aura=$((cur_aura + correction))
[ "$d" -gt "${best:-0}" ] 2>/dev/null && best="$d"
[ "$d" -lt "${worst:-0}" ] 2>/dev/null && worst="$d"
rank_for "$new_aura"

# Only own the visible last_* fields if no newer turn has finalised since ours.
update_last=0
[ "$cur_turns" = "$turn_id" ] && update_last=1
if [ "$update_last" -eq 1 ]; then
  last_delta="$d"; last_pack="model"
else
  last_delta="$(state_get last_delta 0)"; last_pack="$(state_get last_pack "")"
fi

build_json \
  schema 1 aura "$new_aura" rank "$RANK_NAME" face "$RANK_FACE" \
  last_delta "$last_delta" last_pack "$last_pack" \
  streak "${streak:-0}" best "${best:-0}" worst "${worst:-0}" \
  turns "$cur_turns" mode "$mode_s" updated "$(date +%s)" \
  | atomic_write "$AURA_STATE"

[ "$update_last" -eq 1 ] && printf '%s' "$v" | atomic_write "$AURA_VERDICT"
lock_release "$lock"

# Rewrite this turn's history line with the model's verdict/delta.
history_rewrite_ts "$ts" "$d" "model" "$tools" "$snippet" "$v"
exit 0
