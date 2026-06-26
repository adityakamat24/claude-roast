# auraline — product brief & build spec

*(working name; final name TBD)*

A Claude Code plugin that runs a live "aura" meter in the statusline. Trivial requests bleed aura, genuinely substantial ones farm it back, and every turn ends with a snap verdict. The whole thing is a joke at the user's own expense that also gently nudges them toward better prompting. It must cost zero tokens by default, ship no credentials, host nothing, and never slow a session down.

This document is written to be handed to Claude Code as a build brief. Read the "Verify first" section before writing any code, because the three APIs this depends on move and the snippets below reflect what was true as of mid-2026, not gospel.

---

## Hard constraints (non-negotiable)

- **Zero tokens by default.** All scoring happens in shell hooks and a shell statusline script. These run outside the model's context window and add nothing to it. The model is never invoked to score anything.
- **No shipped credentials, ever.** The package carries no API key. The one optional model-powered feature (a roast) runs in the user's own already-authenticated Claude session, on demand only.
- **Nothing hosted.** No server of ours is online. Everything runs locally on each user's machine. Distribution is a static git repo.
- **Never block the session.** Every lifecycle hook must read and write small files and exit fast. The statusline script must be near-instant. A joke meter must never be able to make the CLI feel sluggish or break a turn.
- **Recoverable, two-way meter.** Positive deltas must be achievable, not just negative ones. A one-way death spiral goes stale in an afternoon. The fun is in clawing aura back.
- **Claude Code only.** Statuslines and lifecycle hooks are Claude Code features. The desktop and web apps expose no statusline surface, so "on Claude" here means the CLI specifically. Do not attempt a desktop/web version.

---

## Verify first (the moving parts)

Before building, confirm these against the official docs (`code.claude.com/docs`): the **statusline** reference, the **hooks** reference, and the **plugins** reference. They have changed recently. The facts the design relies on, as last checked:

1. **Statusline** is configured in settings via `"statusLine": { "type": "command", "command": "...", "padding": 0 }`. The script receives session JSON on **stdin** with fields like `model.display_name`, `workspace.current_dir`, `session_id`, `transcript_path`, `cost.total_lines_added`, `cost.total_lines_removed`, `context_window.used_percentage`. Crucially it does **not** receive the user's prompt text or Claude's tool calls. A script that exits non-zero or prints nothing blanks the line; a slow script blocks updates and is cancelled if a newer render starts. So: read one file, `printf`, exit 0. Requires the workspace trust dialog to have been accepted.
2. **Hooks** are configured under a `hooks` key (in `settings.json`, or in a plugin's `hooks/hooks.json`, same format). Event names are case-sensitive. The three this uses:
   - `UserPromptSubmit` — fires when the user submits, before Claude processes it. stdin JSON includes `prompt` (the text), `session_id`, `transcript_path`, `cwd`. **Important gotcha:** for this event, anything the hook prints to stdout on exit 0 is injected into the conversation context. We do not want that. The hook must write to a file and emit nothing on stdout.
   - `PostToolUse` — fires after a tool completes. stdin JSON includes `tool_name`, `tool_input` (e.g. `.command` for Bash, `.file_path`/`.content` for Write/Edit), and the tool response. Supports a `matcher` (use `*` or omit, to catch every tool). stdout here is only shown in transcript mode, so it is safe.
   - `Stop` — fires when Claude finishes its reply. stdin JSON includes `last_assistant_message`. This is where the turn's net aura change is committed, because by now we know both what was asked and what Claude actually did.
   - Hooks support `"async": true` (background, non-blocking) and a `"timeout"`. v1 needs neither for the core, since the core is instant, but the optional roast path can use them.
3. **Plugins**: a plugin is a directory with `.claude-plugin/plugin.json` as the **only** file inside `.claude-plugin/`. Every other component (`hooks/`, `commands/`, `scripts/`, a default `settings.json`) sits at the plugin **root**. Reference any script path with `${CLAUDE_PLUGIN_ROOT}` so it resolves on any install. A marketplace is just a git repo with `.claude-plugin/marketplace.json` listing plugins; users run `/plugin marketplace add owner/repo` then `/plugin install name@marketplace`. Reserved names block anything that impersonates official channels, so avoid names beginning `claude-`, `anthropic-`, or `*-official`.

If any of the above has drifted, adapt the implementation and note what changed in the README.

---

## Architecture

Three hooks act as sensors, one JSON file holds the running tally, and the statusline draws it. Everything talks through files. The model is never in the loop.

```
turn begins
  └─ UserPromptSubmit hook  → score prompt heuristics, reset this turn's tool log,
                              write pending.json (prompt delta + reasons). Emit nothing.
  └─ PostToolUse hook (×N)  → append each tool call (name + a short signal) to tools.jsonl.
  └─ Stop hook              → read pending.json + tools.jsonl, compute the turn's net
                              delta, pick a verdict line, update state.json atomically,
                              append to history + hall of shame, clear the scratch.
statusline (every render)   → read state.json, draw the meter. Fast. No logic.
```

### State and scratch locations

- The meter lives at `~/.claude/aura/state.json` (stable, survives plugin updates).
- **Do not** store state under `${CLAUDE_PLUGIN_ROOT}`. Marketplace installs live in a versioned cache directory that changes on every update, which would wipe the user's aura. Scripts resolve from the plugin root; state lives in `~/.claude/aura/`.
- Per-turn scratch is keyed by session so concurrent sessions never clobber each other: `~/.claude/aura/sessions/<session_id>/pending.json` and `tools.jsonl`.

### Atomic writes

The statusline reads while a hook writes. Always write to `state.json.tmp` then `mv` it over `state.json` (rename is atomic on POSIX), so a render can never catch a half-written file and flicker garbage.

---

## Scoring model

Two signals, combined at `Stop`. Make all numbers, word lists, rank tiers, and verdict lines live in a `config.json` so the whole thing is tunable and themeable without touching code.

### Prompt signal (scored in `UserPromptSubmit`)

A starting ruleset, all configurable:

- One or two word prompts ("hi", "yo", "thanks", "ok") → small drain.
- Folder/file-only intent in the text ("create a folder", "make a directory", "mkdir", "rename this file") → drain.
- Near-duplicate of the previous prompt (compare a hash of the last prompt) → drain, verdict along the lines of asking the same thing twice.
- Long, specific, structured prompt (over a length threshold, contains a fenced code block, multiple sentences) → gain. Keep the positive signal structural rather than a cringe keyword list; an optional small "galaxy-brain" wordlist bonus can exist in config for users who want it, off by default.
- All-caps or repeated "pls pls pls" → flavour drain, tiny.

### Tool signal (logged in `PostToolUse`, judged in `Stop`)

This is where the best joke lives, and it is free because the hook hands us exactly what Claude ran.

- **The signature gag:** the entire turn resolved to exactly one tool call, a Bash command matching `^(mkdir|touch|ls|pwd|cd|echo|cat)\b` → big drain. This is the "you summoned a frontier model to make one directory" verdict and it should be the centrepiece.
- One trivial Read and nothing else → small drain.
- Zero tools, pure chat answer → neutral.
- Several Edit/Write/MultiEdit calls across multiple files → gain, scaled loosely by how many. Count of substantive tool calls is a good enough proxy for substance.
- A turn that ran tests or a build (Bash invoking `pytest`, `cargo`, `npm test`, etc.) → gain, "actually shipped something".

The net turn delta is the sum of the prompt delta and the tool delta. Scoring partly on what Claude was *forced to do*, not only on the words, is what makes the verdicts feel weirdly perceptive.

### Verdict packs

`config.json` holds arrays of one-liners keyed by event type (`trivial_solo`, `dupe_prompt`, `one_word`, `galaxy_brain`, `shipped_code`, …). `Stop` picks one at random from the matching pack. This is what makes the meter feel alive, and "submit your own verdict pack" is a natural community hook. Keep the register savage but never mean, and never about anything other than the request itself.

---

## State schema (`state.json`)

```json
{
  "aura": 320,
  "rank": "locked in",
  "face": "😎",
  "last_delta": -150,
  "last_verdict": "summoned a frontier model to run mkdir. respect lost.",
  "streak": 0,
  "mode": "lifetime",
  "history": [
    { "ts": 0, "delta": -150, "verdict": "...", "snippet": "make a folder called test" }
  ],
  "hall_of_shame": [
    { "ts": 0, "delta": -150, "verdict": "...", "snippet": "..." }
  ]
}
```

- **Rank tiers** (tunable), low to high: `smooth brain 💀` / `certified npc 😐` / `mid 🙂` / `locked in 😎` / `galaxy brain 🧠` / `aura god ✨`, at score thresholds.
- `face` follows the current tier; the rendered `last_delta` token is what gives immediate per-turn feedback.
- `hall_of_shame` keeps the five lowest-delta moments so the user can roast themselves on demand.
- Default `mode` is `lifetime` (a permanent record). A `session` mode that resets each conversation is a config flag.

---

## Statusline render

One line, read straight from `state.json`. Shape:

```
😎 aura 320  [▓▓▓▓▓░░░░░]  locked in   last: shipped 6 edits +180
💀 aura -980 [░░░░░░░░░░]  smooth brain  last: mkdir (alone) -150
```

Mood face, the number, a bar, the rank, and the last delta with its verdict tail. Colour the delta token green/red by sign. Provide a short variant for narrow terminals (drop the bar and verdict tail). Handle the first-run case where no state file exists yet by showing a neutral starting meter rather than blanking.

---

## The `/aura` command

A single slash command (a markdown command file, or a skill if the newer format is preferred; note `commands/` is now considered legacy but still supported) that branches on `$ARGUMENTS`:

- `/aura` — show the current score and rank.
- `/aura reset` — reset the meter (confirm first).
- `/aura shame` — print the hall of shame.
- `/aura roast` — **the only model-powered feature.** It reads `state.json` and the recent history and produces a savage one-line verdict, generated by the *current* Claude session. That means it runs on the user's own auth, costs only their normal usage, and only when they explicitly invoke it. Never fire this automatically per turn; doing so would quietly burn a user's quota and get the plugin uninstalled. On-demand only.

---

## Packaging and distribution

Ship as a Claude Code plugin, distributed through a git-hosted marketplace.

```
auraline/
├── .claude-plugin/
│   └── plugin.json          # manifest ONLY (name, description, version, author, repository, license)
├── hooks/
│   └── hooks.json           # UserPromptSubmit, PostToolUse (matcher "*"), Stop
│                            # commands reference ${CLAUDE_PLUGIN_ROOT}/scripts/...
├── scripts/
│   ├── score-prompt.sh      # UserPromptSubmit handler
│   ├── log-tool.sh          # PostToolUse handler
│   ├── finalise.sh          # Stop handler — commits the delta, atomic write
│   └── statusline.sh        # the renderer
├── commands/
│   └── aura.md              # /aura show | reset | shame | roast
├── config.json              # thresholds, deltas, rank tiers, verdict packs
├── settings.json            # default settings on enable — wires up statusLine
└── README.md                # install, demo GIF, how to write a verdict pack
```

Notes:

- **Statusline wiring is the one real UX decision.** Only one statusline can be active at a time. Shipping `statusLine` in the plugin's default `settings.json` is the clean path when the user has none. For users who already run a statusline they like, document a compose option: the aura segment is small and self-contained, so it can either be the statusline or be appended to an existing one. Default to shipping it; document composition.
- Test locally with `claude --plugin-dir ./auraline` and `/reload-plugins` between edits (hook and statusline changes need a reload or restart; only SKILL.md edits are live).
- The marketplace repo adds `.claude-plugin/marketplace.json` and a README with the two install commands and a demo GIF. MIT licence.

---

## Build order

0. **Verify the three APIs** against current docs (see "Verify first"). Print a one-line compatibility note for the README.
1. **Local prototype, no plugin.** Wire the three hooks plus the statusline into `~/.claude/settings.json` pointing at scripts in a dev dir. Get the meter moving with prompt heuristics plus the single-`mkdir` detector and two hardcoded verdict lines. Atomic writes from the start. Milestone: the number visibly moves and survives a restart.
2. **Real scoring engine.** Externalise everything to `config.json`. Full prompt and tool signals, duplicate-prompt detection, history, hall of shame.
3. **Statusline polish.** Faces, coloured delta token, bar, rank, verdict tail, narrow-terminal variant, graceful first run.
4. **`/aura` command.** show / reset / shame / roast, the roast generated in-session on demand.
5. **Package as a plugin.** Move scripts under the plugin root, write the manifest and `hooks/hooks.json` with `${CLAUDE_PLUGIN_ROOT}` paths, ship the default `settings.json`, keep state in `~/.claude/aura/`. Test via `--plugin-dir`.
6. **Marketplace.** `marketplace.json`, public repo, README with install commands and a GIF, a verdict-pack contribution guide.

## Non-goals

No server or hosting. No bundled credentials. No desktop or web version. No automatic token spend (the roast is opt-in, on demand). It is a joke, so keep it light and never let it block or break a session.

## Open questions to confirm with the user

- Final name.
- Lifetime meter (default) versus per-session reset.
- Whether to ship the optional on-demand roast in v1 or keep v1 purely heuristic and add the roast later.
- Windows support now (PowerShell / Git Bash variants of the scripts) or as a fast-follow.
