#!/usr/bin/env bash
# score-prompt.sh — UserPromptSubmit hook
# Computes PROMPT signal and writes pending line; emits nothing on stdout.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

in="$(cat)"
sid="$(json_str "$in" session_id)"
[ -z "$sid" ] && sid=default

msg="$(json_str "$in" user_message)"
[ -z "$msg" ] && msg="$(json_str "$in" prompt)"

ensure_home
mkdir -p "$(sess_dir "$sid")"

# Reset this turn's tool log
: > "$(sess_dir "$sid")/tools.log"

# Normalised forms
lmsg="$(lower "$(trim "$msg")")"
words="$(word_count "$msg")"
chars="${#msg}"
hash="$(prompt_hash "$lmsg")"

# ── Detect each signal flag ───────────────────────────────────────────────────

# dupe: compare against stored hash (non-empty only)
f_dupe=0
last_hash=""
[ -f "$AURA_LASTHASH" ] && last_hash="$(cat "$AURA_LASTHASH" 2>/dev/null)"
[ -n "$last_hash" ] && [ "$hash" = "$last_hash" ] && f_dupe=1

# one_word
f_one_word=0
one_word_max="$(cfg_num one_word_max_words 2)"
one_word_pat="$(cfg_str one_word_pattern)"
if [ "$words" -le "$one_word_max" ] && [ -n "$one_word_pat" ] && [[ "$lmsg" =~ $one_word_pat ]]; then
  f_one_word=1
fi

# folder_only (lower(msg), not trimmed)
f_folder_only=0
folder_pat="$(cfg_str folder_only_pattern)"
lmsg_raw="$(lower "$msg")"
if [ -n "$folder_pat" ] && [[ "$lmsg_raw" =~ $folder_pat ]]; then
  f_folder_only=1
fi

# shouting
f_shouting=0
shouting_min="$(cfg_num shouting_min_len 6)"
shouting_caps_thresh="$(cfg_num shouting_caps_ratio 80)"
cr="$(caps_ratio "$msg")"
[ "$chars" -ge "$shouting_min" ] && [ "$cr" -ge "$shouting_caps_thresh" ] && f_shouting=1

# begging (lower(msg))
f_begging=0
begging_pat="$(cfg_str begging_pattern)"
if [ -n "$begging_pat" ] && [[ "$lmsg_raw" =~ $begging_pat ]]; then
  f_begging=1
fi

# detailed (gain): chars OR sentences OR code fence
f_detailed=0
detailed_min_chars="$(cfg_num detailed_min_chars 240)"
detailed_min_sent="$(cfg_num detailed_min_sentences 3)"
sentences="$(count_sentences "$msg")"
has_code_fence "$msg" && fence=1 || fence=0
if [ "$chars" -ge "$detailed_min_chars" ] || [ "$sentences" -ge "$detailed_min_sent" ] || [ "$fence" -eq 1 ]; then
  f_detailed=1
fi

# galaxy (optional)
f_galaxy=0
if [ "$(cfg_num galaxy_enabled 0)" -eq 1 ]; then
  galaxy_pat="$(cfg_str galaxy_pattern)"
  if [ -n "$galaxy_pat" ] && [[ "$lmsg" =~ $galaxy_pat ]]; then
    f_galaxy=1
  fi
fi

# ── Compute additive delta ─────────────────────────────────────────────────────

prompt_delta=0

[ "$f_dupe" -eq 1 ]        && prompt_delta=$((prompt_delta + $(cfg_num dupe_delta 0)))
[ "$f_one_word" -eq 1 ]    && prompt_delta=$((prompt_delta + $(cfg_num one_word_delta 0)))
[ "$f_folder_only" -eq 1 ] && prompt_delta=$((prompt_delta + $(cfg_num folder_only_delta 0)))
[ "$f_shouting" -eq 1 ]    && prompt_delta=$((prompt_delta + $(cfg_num shouting_delta 0)))
[ "$f_begging" -eq 1 ]     && prompt_delta=$((prompt_delta + $(cfg_num begging_delta 0)))

if [ "$f_detailed" -eq 1 ]; then
  gain=$(( $(cfg_num detailed_base 50) + (chars / 100) * $(cfg_num detailed_per_100 15) ))
  [ "$fence" -eq 1 ] && gain=$((gain + $(cfg_num detailed_code_fence_bonus 60)))
  max_gain="$(cfg_num detailed_max 150)"
  [ "$gain" -gt "$max_gain" ] && gain="$max_gain"
  prompt_delta=$((prompt_delta + gain))
fi

[ "$f_galaxy" -eq 1 ] && prompt_delta=$((prompt_delta + $(cfg_num galaxy_delta 0)))

# Clamp
prompt_delta="$(clampi "$prompt_delta" "$(cfg_num clamp_prompt_min -120)" "$(cfg_num clamp_prompt_max 150)")"

# ── Pack precedence: dupe_prompt > one_word > folder_only > detailed_prompt > shouting > begging > "" ──

if   [ "$f_dupe" -eq 1 ];        then pack="dupe_prompt"
elif [ "$f_one_word" -eq 1 ];    then pack="one_word"
elif [ "$f_folder_only" -eq 1 ]; then pack="folder_only"
elif [ "$f_detailed" -eq 1 ];    then pack="detailed_prompt"
elif [ "$f_shouting" -eq 1 ];    then pack="shouting"
elif [ "$f_begging" -eq 1 ];     then pack="begging"
else                                   pack=""
fi

# ── Persist ───────────────────────────────────────────────────────────────────

# Update last_prompt_hash AFTER scoring
printf '%s' "$hash" | atomic_write "$AURA_LASTHASH"

# Write pending: prompt_delta|pack|hash|words|snippet
snippet="$(field_clean "${msg:0:60}")"
printf '%s' "${prompt_delta}|${pack}|${hash}|${words}|${snippet}" | atomic_write "$(sess_dir "$sid")/pending"

# ── self mode: ask THE SESSION MODEL to self-rate via a hidden marker ────────
# UserPromptSubmit stdout (exit 0) is injected into the model's context. In
# every other mode we emit nothing. The format example below uses <number> /
# <verdict> placeholders (which contain '>') so it can never match the Stop
# hook's extractor — only the model's real marker (no '>' in it) matches.
jmode="${AURA_JUDGE_MODE:-$(cfg_str judge_mode off)}"
if [ "$jmode" = "self" ]; then
  cat <<'INSTR'
[claude-roast meter] When you have fully finished answering, append on a new final line exactly one HTML comment rating how well this turn used you, with nothing after it. Use this format: <!--aura: <number> | <verdict> --> where <number> is an integer from -300 (trivial or wasteful: a greeting, one mkdir, folder busywork, asking the same thing twice) to 300 (substantial: real multi-file changes, running tests, solving something hard), and <verdict> is ONE genuinely funny, savage-but-fair line of at most 12 words about the request only (never the person), containing no >, |, or quote characters. The comment is hidden from the user; it just drives a status-line aura meter. Keep doing your normal work first; this is only a trailing tag.
INSTR
fi

exit 0
