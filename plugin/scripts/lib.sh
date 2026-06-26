#!/usr/bin/env bash
# claude-roast — shared library. Pure bash, ZERO external deps beyond coreutils
# (no jq, no flock, no python). Sourced by every hook/renderer/cli script.
#
# Design notes:
#  - state.json is FLAT (scalars only) so it parses with grep/sed, no jq.
#  - patterns in config.json are POSIX ERE used with bash [[ =~ ]] (no backslash
#    escapes by design), so reading them out of JSON needs no un-escaping.
#  - all writes that a renderer might read concurrently go through atomic_write
#    (write tmp + mv), because flock is unavailable.

# ── Paths (AURA_HOME overridable for tests) ──────────────────────────────────
AURA_HOME="${AURA_HOME:-$HOME/.claude/aura}"
AURA_STATE="$AURA_HOME/state.json"         # flat, CONTROLLED scalars only (no free-form strings)
AURA_VERDICT="$AURA_HOME/last_verdict.txt" # the one free-form string, kept out of JSON (quote-safe)
AURA_HISTORY="$AURA_HOME/history.log"      # pipe-delimited: ts|delta|pack|tools|snippet|verdict
AURA_SESS="$AURA_HOME/sessions"
AURA_LASTHASH="$AURA_HOME/last_prompt_hash"

# Plugin root = dir containing this lib's parent (scripts/..). Overridable.
_aura_self_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd; }
AURA_PLUGIN="${AURA_PLUGIN:-$(cd "$(_aura_self_dir)/.." 2>/dev/null && pwd)}"

# Resolve data files: a user/runtime copy in AURA_HOME wins over the plugin copy.
cfg_path()     { if [ -f "$AURA_HOME/config.json" ]; then printf '%s' "$AURA_HOME/config.json"; else printf '%s' "$AURA_PLUGIN/config.json"; fi; }
ranks_path()   { if [ -f "$AURA_HOME/ranks.tsv" ];   then printf '%s' "$AURA_HOME/ranks.tsv";   else printf '%s' "$AURA_PLUGIN/ranks.tsv";   fi; }
verdicts_dir() { if [ -d "$AURA_HOME/verdicts" ];    then printf '%s' "$AURA_HOME/verdicts";    else printf '%s' "$AURA_PLUGIN/verdicts";    fi; }
judge_prompt_path() { if [ -f "$AURA_HOME/judge-prompt.txt" ]; then printf '%s' "$AURA_HOME/judge-prompt.txt"; else printf '%s' "$AURA_PLUGIN/judge-prompt.txt"; fi; }

# ── JSON read (flat, by unique key name; pure bash) ──────────────────────────
# json_str <json> <key>  -> first string value for key, quotes stripped.
json_str() {
  printf '%s' "$1" | tr '\n' ' ' \
    | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 \
    | sed 's/.*:[[:space:]]*"//; s/"$//'
}
# json_num <json> <key>  -> first numeric value (handles negatives/decimals).
json_num() {
  printf '%s' "$1" | tr '\n' ' ' \
    | grep -o "\"$2\"[[:space:]]*:[[:space:]]*-\{0,1\}[0-9][0-9.]*" | head -1 \
    | sed 's/.*:[[:space:]]*//'
}

# ── Config access (cached) ───────────────────────────────────────────────────
AURA_CFG_CACHE=""
_cfg() { [ -n "$AURA_CFG_CACHE" ] || AURA_CFG_CACHE="$(cat "$(cfg_path)" 2>/dev/null)"; printf '%s' "$AURA_CFG_CACHE"; }
# cfg_num <key> [default]
cfg_num() { local v; v="$(json_num "$(_cfg)" "$1")"; if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "${2:-0}"; fi; }
# cfg_str <key> [default]
cfg_str() { local v; v="$(json_str "$(_cfg)" "$1")"; if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "${2:-}"; fi; }

# ── Atomic write (content on stdin) ──────────────────────────────────────────
atomic_write() {  # atomic_write <path>
  local path="$1" tmp
  mkdir -p "$(dirname "$path")" 2>/dev/null
  tmp="$(mktemp "${path}.XXXXXX" 2>/dev/null)" || tmp="${path}.tmp.$$"
  cat > "$tmp" && mv -f "$tmp" "$path"
}

# ── String / JSON helpers ────────────────────────────────────────────────────
json_escape() {  # escape one scalar string for embedding inside JSON
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/ }"; s="${s//$'\t'/ }"; s="${s//$'\r'/}"
  printf '%s' "$s"
}
# build_json k1 v1 k2 v2 ...  -> flat JSON object. Pure-integer values are
# emitted unquoted; everything else is quoted + escaped.
build_json() {
  local out="{" first=1 k v
  while [ "$#" -ge 2 ]; do
    k="$1"; v="$2"; shift 2
    if [ "$first" -eq 1 ]; then first=0; else out+=","; fi
    if [[ "$v" =~ ^-?[0-9]+$ ]]; then out+="\"$k\":$v"; else out+="\"$k\":\"$(json_escape "$v")\""; fi
  done
  out+="}"
  printf '%s' "$out"
}
sanitize() { printf '%s' "$1" | tr -c 'a-zA-Z0-9_.-' '_'; }
# field_clean: make a free-form string safe for one pipe-delimited history field
# (strip | and CR/LF/TAB, collapse runs of space, trim). Quote-safe by construction.
field_clean() {
  local s="$1"
  s="${s//|/ }"; s="${s//$'\n'/ }"; s="${s//$'\r'/ }"; s="${s//$'\t'/ }"
  s="$(printf '%s' "$s" | tr -s ' ')"
  s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}
read_verdict() { [ -f "$AURA_VERDICT" ] && cat "$AURA_VERDICT" 2>/dev/null; }
prompt_hash() {  # stable-ish hash of normalized prompt; cksum with length fallback
  local s="$1" h
  h="$(printf '%s' "$s" | cksum 2>/dev/null | awk '{print $1}')"
  [ -n "$h" ] || h="${#s}"
  printf '%s' "$h"
}

# ── Math ─────────────────────────────────────────────────────────────────────
clampi() { local v="$1" lo="$2" hi="$3"; [ "$v" -lt "$lo" ] 2>/dev/null && v="$lo"; [ "$v" -gt "$hi" ] 2>/dev/null && v="$hi"; printf '%s' "$v"; }

# ── State read (flat scalars) ────────────────────────────────────────────────
state_get() {  # state_get <key> [default]
  local k="$1" def="${2:-}" js v
  [ -f "$AURA_STATE" ] || { printf '%s' "$def"; return; }
  js="$(cat "$AURA_STATE" 2>/dev/null)"
  v="$(json_num "$js" "$k")"; [ -n "$v" ] || v="$(json_str "$js" "$k")"
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$def"; fi
}

# ── Ranks / verdicts ─────────────────────────────────────────────────────────
# rank_for <aura>  -> sets globals RANK_NAME, RANK_FACE (highest matching tier).
rank_for() {
  local aura="$1" thr name face
  RANK_NAME="mid"; RANK_FACE="🙂"
  while IFS='|' read -r thr name face; do
    case "$thr" in ''|\#*) continue;; esac
    if [ "$aura" -ge "$thr" ] 2>/dev/null; then RANK_NAME="$name"; RANK_FACE="$face"; fi
  done < "$(ranks_path)"
}
# pick_verdict <pack>  -> one random non-comment line from verdicts/<pack>.txt.
pick_verdict() {
  local pack="$1" f l; local -a raw=() clean=()
  f="$(verdicts_dir)/$pack.txt"
  [ -f "$f" ] || f="$(verdicts_dir)/neutral.txt"
  [ -f "$f" ] || { printf ''; return; }
  mapfile -t raw < "$f"
  for l in "${raw[@]}"; do
    case "$l" in ''|\#*) continue;; esac
    clean+=("$l")
  done
  [ "${#clean[@]}" -eq 0 ] && { printf ''; return; }
  printf '%s' "${clean[$((RANDOM % ${#clean[@]}))]}"
}

# ── Render helpers ───────────────────────────────────────────────────────────
# bar <aura>  -> filled/empty bar of width bar_width over [bar_floor, bar_ceil].
bar() {
  local aura="$1" w floor ceil span pos f e i out=""
  w="$(cfg_num bar_width 10)"; floor="$(cfg_num bar_floor -300)"; ceil="$(cfg_num bar_ceil 1200)"
  span=$((ceil - floor)); [ "$span" -le 0 ] && span=1
  pos=$(( ( (aura - floor) * w + span/2 ) / span ))
  [ "$pos" -lt 0 ] && pos=0; [ "$pos" -gt "$w" ] && pos="$w"
  f="$pos"; e=$((w - f))
  for ((i=0;i<f;i++)); do out+="▓"; done
  for ((i=0;i<e;i++)); do out+="░"; done
  printf '%s' "$out"
}

# ── Prompt heuristic helpers (used by score-prompt.sh) ───────────────────────
word_count()     { local -a a; read -ra a <<<"$1"; printf '%s' "${#a[@]}"; }
has_code_fence() { case "$1" in *'```'*) return 0;; *) return 1;; esac; }
count_sentences(){ local n; n="$(printf '%s' "$1" | grep -o '[.!?]' | wc -l | tr -d ' ')"; printf '%s' "${n:-0}"; }
caps_ratio()     {  # integer percent uppercase among alphabetic chars
  local s="$1" up lo total
  up="$(printf '%s' "$s" | tr -cd 'A-Z' | wc -c | tr -d ' ')"
  lo="$(printf '%s' "$s" | tr -cd 'a-z' | wc -c | tr -d ' ')"
  total=$((up + lo)); [ "$total" -eq 0 ] && { printf '0'; return; }
  printf '%s' "$(( up * 100 / total ))"
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
trim()  { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# ── Session scratch ──────────────────────────────────────────────────────────
sess_dir() { printf '%s/%s' "$AURA_SESS" "$(sanitize "${1:-default}")"; }
ensure_home() { mkdir -p "$AURA_HOME" "$AURA_SESS" "$(verdicts_dir)" 2>/dev/null; mkdir -p "$AURA_HOME" "$AURA_SESS" 2>/dev/null; }

# ── Concurrency lock (mkdir-based; flock is unavailable) ─────────────────────
# lock_acquire <lockdir> [timeout_ms] — atomic mkdir spinlock with stale-steal.
lock_acquire() {
  local lock="$1" timeout="${2:-3000}" waited=0
  while ! mkdir "$lock" 2>/dev/null; do
    # steal a stale lock (holder died) — older than 15s
    if [ -d "$lock" ]; then
      local age; age=$(( $(date +%s) - $(stat -c %Y "$lock" 2>/dev/null || echo 0) ))
      [ "$age" -gt 15 ] 2>/dev/null && rmdir "$lock" 2>/dev/null
    fi
    sleep 0.1 2>/dev/null || sleep 1
    waited=$((waited + 100))
    [ "$waited" -ge "$timeout" ] && return 1
  done
  return 0
}
lock_release() { rmdir "$1" 2>/dev/null; }

# history_rewrite_ts <ts> <delta> <pack> <tools> <snippet> <verdict>
# Replace the history.log line whose first field == ts (used by the async judge).
history_rewrite_ts() {
  local ts="$1" d="$2" pack="$3" tools="$4" snip="$5" verd="$6" tmp line found=0
  [ -f "$AURA_HISTORY" ] || return 0
  tmp="$(mktemp 2>/dev/null)" || tmp="$AURA_HISTORY.tmp.$$"
  while IFS= read -r line; do
    case "$line" in
      "$ts|"*) printf '%s\n' "${ts}|${d}|${pack}|${tools}|$(field_clean "$snip")|$(field_clean "$verd")" >> "$tmp"; found=1 ;;
      *)       printf '%s\n' "$line" >> "$tmp" ;;
    esac
  done < "$AURA_HISTORY"
  if [ "$found" -eq 1 ]; then mv -f "$tmp" "$AURA_HISTORY"; else rm -f "$tmp"; fi
}

# ── ANSI ─────────────────────────────────────────────────────────────────────
AURA_RST=$'\033[0m'; AURA_DIM=$'\033[2m'
AURA_RED=$'\033[31m'; AURA_GRN=$'\033[32m'; AURA_YLW=$'\033[33m'
AURA_CYN=$'\033[36m'; AURA_MAG=$'\033[35m'; AURA_BLU=$'\033[34m'
