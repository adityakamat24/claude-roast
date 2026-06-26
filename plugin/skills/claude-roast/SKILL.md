---
name: claude-roast
description: "Show/roast/reset your aura meter. Trivial prompts bleed aura; real work farms it back."
disable-model-invocation: true
user-invocable: true
argument-hint: "[show|shame|roast|reset|install]"
---

# claude-roast

Branch on `$ARGUMENTS` (default: `show` when empty).

The runtime CLI lives at `$HOME/.claude/aura/cli.sh` after install. The plugin
fallback is at `$AURA_PLUGIN/scripts/cli.sh` (available before install).

Helper — resolve CLI path:
```
CLI="$HOME/.claude/aura/cli.sh"
[ -f "$CLI" ] || CLI="$(bash -c 'source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh" 2>/dev/null; printf "%s" "$AURA_PLUGIN"')/scripts/cli.sh"
```

---

## empty or `show`

Run the following in a Bash tool and print the output verbatim:
```bash
CLI="$HOME/.claude/aura/cli.sh"; [ -f "$CLI" ] || CLI="${CLAUDE_PLUGIN_ROOT}/scripts/cli.sh"
bash "$CLI" show
```

---

## `shame`

Run the following in a Bash tool and print the output verbatim:
```bash
CLI="$HOME/.claude/aura/cli.sh"; [ -f "$CLI" ] || CLI="${CLAUDE_PLUGIN_ROOT}/scripts/cli.sh"
bash "$CLI" shame
```

---

## `reset`

**Ask the user to confirm** before doing anything ("Reset your aura to zero — are you sure?"). Only proceed on an affirmative reply. On confirmation, run:
```bash
CLI="$HOME/.claude/aura/cli.sh"; [ -f "$CLI" ] || CLI="${CLAUDE_PLUGIN_ROOT}/scripts/cli.sh"
bash "$CLI" reset
```
Print the output verbatim.

---

## `install`

1. Run the seed step:
   ```bash
   CLI="$HOME/.claude/aura/cli.sh"; [ -f "$CLI" ] || CLI="${CLAUDE_PLUGIN_ROOT}/scripts/cli.sh"
   bash "$CLI" seed
   ```
   Print the output verbatim.

2. Read `~/.claude/settings.json` with the Read tool.

3. Look for an existing `statusLine` → `command` key:

   **If no `statusLine` key is found:** Tell the user to add the following to
   `~/.claude/settings.json` (in the top-level object):
   ```json
   "statusLine": {"type":"command","command":"bash \"$HOME/.claude/aura/statusline.sh\""}
   ```

   **If a `statusLine.command` already exists:** Run the wrapper generator,
   passing their existing command as the sole argument:
   ```bash
   bash "$HOME/.claude/aura/cli.sh" wrapper '<their existing command value>'
   ```
   Print the output verbatim. This generates `~/.claude/aura/statusline-wrapper.sh`
   and prints the exact `statusLine` snippet to use.

   **Important:** Never overwrite `~/.claude/settings.json` yourself. Always
   tell the user to make the edit and remind them to back up the file first.

---

## `roast`

This is the only model-powered branch.

1. Read `~/.claude/aura/state.json` with the Read tool.
2. Read `~/.claude/aura/history.log` (last ~15 lines via Bash `tail -15`).
3. Based on the aura score, rank, recent deltas, and verdict snippets, produce
   **exactly one** savage, original one-liner that roasts the user's recent
   prompting patterns.

Rules for the roast:
- Savage but never mean — attack the *requests*, never the person's identity.
- No preamble, no explanation, no markdown. Output the single line only.
- Make it specific to what the data actually shows (one-word prompts? folder ops?
  all reads? a losing streak?). Generic roasts are aura-negative.
