# clafra

**Keeps Claude Code skills true.**

Project skills (`.claude/skills/<name>/SKILL.md`) are knowledge you hand to Claude: "fees
use banker's rounding", "the ledger is append-only", "the tasting flow has 5 chapters".
The code moves on, the skill doesn't, and Claude keeps following instructions that
stopped being true.

clafra makes each skill declare what it depends on and how to tell when it has stopped
holding. A small `clafra.json` next to the `SKILL.md` lists the files the skill watches
and shell checks that **fail** when the skill is wrong. clafra re-runs those checks, tells
Claude (and you) when a skill has gone stale, and governs how skills are created and
retired.

> **Status: early (0.x).** Used daily by its author on a few real repos. Tested on Linux
> and macOS in CI, with Claude Code 2.1.x. Interfaces may change before 1.0.

## Quickstart

Install the plugin from inside Claude Code:

```
/plugin marketplace add PopGIGI/clafra-plugin
/plugin install clafra@clafra
```

Then, in a repo, ask Claude to turn something it keeps relearning into a governed skill
(`/clafra:create`), or write the sidecar yourself next to an existing skill, e.g. `.claude/skills/fee-calc/clafra.json`:

```json
{
  "intent": "Compute order fees with Decimal money and banker's rounding via apply_fee",
  "watches": ["src/fees.py"],
  "checks": [
    "grep -q 'ROUND_HALF_EVEN' src/fees.py",
    "cd src && python3 -c 'from decimal import Decimal as D; from fees import apply_fee; assert apply_fee(D(\"10.00\")) == D(\"10.25\")'"
  ],
  "stack_dependencies": ["requirements.txt"],
  "evidence": ["session:a", "session:b", "session:c"],
  "staleness_days": 30
}
```

Start a session in the repo. Nothing runs yet: the session-start notice asks you to approve
the check commands **in your own terminal**, and gives the exact command (clafra never runs
a command you haven't seen):

```bash
cd /path/to/repo && ~/.claude/plugins/cache/clafra/clafra/<version>/bin/clafra trust
```

From then on, every session starts with a validation pass. If someone changes the
rounding mode, Claude is told at session start that `fee-calc` is STALE and why, before
it reads `src/fees.py`.

clafra writes its own `.gitignore` entries (`.clafra/.gitignore`, `.claude/rules/.gitignore`).
If your repo ignores `*.log` or `.claude/` wholesale, re-include the audit trail and skills:
`!.clafra/audit.log`, `.claude/*` + `!.claude/skills/`.

**Requirements:** Claude Code with plugin support, Python ≥ 3.9 (stdlib only), git, bash.
The demo also needs `jq`.

## How it works

Governed skills are ordinary Claude Code skills plus a tracked `clafra.json` sidecar.
Runtime state (status, last validated commit) lives in `.clafra/state.json`, which is
gitignored, so validation never dirties the repo. `.clafra/audit.log` and
`.clafra/deprecated/` are the audit trail and stay tracked.

| Mechanism | How | Demo scenario |
|---|---|---|
| Read-time context | each skill compiles to a generated, gitignored `.claude/rules/clafra-<skill>.md` scoped to its `watches`; Claude Code loads it natively when Claude **reads** (or edits) a matching file, i.e. while planning. Stale skills' rules say STALE | 1 |
| End-of-turn check | `SessionStart` records a baseline (HEAD + hash of dirty files); the `Stop` hook re-runs checks of skills whose files changed this session (by any means, including Bash) and sends Claude back once to fix the code or update the skill | 4c |
| Drift at session start | `SessionStart` runs `clafra validate` (incremental: a skill's checks re-run only when its watched, check-referenced, stack or skill files changed; `--full` forces all); stale skills are injected as context | 2, 4b |
| Deprecation proposal | a skill stale longer than its `staleness_days` (default 30) is flagged "propose deprecation" | 6 |
| Maintenance review (on demand) | `clafra gather` (pure code) → `claude -p --json-schema` → findings must cite an **exact** fact atom or they are dropped | 3 |
| Trust | check commands run only after a human approves them with `clafra trust` in an interactive terminal; approvals (a fingerprint of each skill's checks) live outside the repo in `~/.config/clafra/trust.json`, so a cloned repo can't trust itself, and any change to a check (a pull, an agent loosening it) makes the skill UNTRUSTED until re-approved | 7 |
| Generated blocks | docs hold `<!-- clafra:begin NAME -->…<!-- clafra:end NAME -->`; NAME is a generator declared in the skill's `clafra.json` (`"generate": {NAME: cmd}`, fingerprinted by trust, so a doc can never introduce a command). `clafra sync` rewrites only between markers and verifies every byte outside is unchanged; an out-of-date or hand-edited block fails validation | 8 |
| Creation guard | `clafra create`: overlap ≥ 0.7 blocked, 0.4–0.7 needs a human decision, < 3 evidence refs blocked, checks must pass at creation | 5 |
| Deprecation | `clafra deprecate`: stale only (unless `--force`), moved to `.clafra/deprecated/` with `deprecation.json` | 6 |

Plugin skills: `/clafra:status`, `/clafra:create`, `/clafra:review`, `/clafra:deprecate`.
`clafra` is on Claude's Bash PATH while the plugin is loaded. Hooks do nothing in repos
without governed skills.

### Checks must be able to fail

A check is only useful if breaking the skill's claim breaks the check. `grep -q 'fee'
src/fees.py` stays green long after the fee logic changed. Prefer checks that exercise the
behaviour (call the function, run the targeted test) or pin the exact fact the skill
states. A quick way to test a check: mutate the code the way the skill warns against and
confirm `clafra validate` goes red.

### Deterministic doc edits

clafra never edits prose with a model. Facts derivable from code go in generated blocks
(`clafra sync`, deterministic, scoped to markers). Prose that states a fact is written by
a human (or a reviewed session) and guarded by a check. Pure prose is left alone.

## Trust model

Checks are shell commands that hooks and the nightly job run automatically, so:

- In a repo you haven't approved, nothing runs. The session-start notice asks **you** to
  run `clafra trust`, which lists every command first. New skills and changed checks stay
  pending until approved; their status is `untrusted` (never green) and their rules say
  UNTRUSTED.
- If the agent changes a skill's checks during a session, the end-of-turn hook sends it
  back to tell you. It cannot make a weakened check pass silently.
- Text injected into context is built only from repo-authored fields (intent, check
  strings, paths), stripped of control characters and length-capped. Command output is
  never injected.

Limits: `clafra trust` refuses without a TTY, but an agent with an unrestricted shell can
fake one (`script`) or write the trust file. Close the obvious paths with user-level deny
rules in `~/.claude/settings.json`:

```json
"permissions": { "deny": ["Bash(clafra trust:*)", "Bash(script:*)",
                          "Edit(~/.config/clafra/**)", "Write(~/.config/clafra/**)"] }
```

## Nightly validation (optional)

`bin/clafra-cron` runs `clafra validate --full` (every check, no cache, **no LLM**) for each
repo listed in `~/.config/clafra/repos` (one absolute path per line; override with
`$CLAFRA_REPOS`). Results land in each repo's `.clafra/state.json`, so stale skills surface
at the next session start and in the read-time rules. Repos are isolated from each other.

```
17 3 * * * /path/to/clafra/bin/clafra-cron >> ~/.local/state/clafra/cron.log 2>&1
```

Point cron at a stable copy, such as a git clone of this repo. The plugin cache path
changes with each version.

## Demo

```bash
demo/demo.sh --offline   # mechanical assertions, no model calls
demo/demo.sh             # + live assertions via claude -p (haiku), isolated HOME
```

The demo copies `demo/fixture/` (a tiny fee calculator with two governed skills) to a temp
repo and runs eight scenarios. Every assertion can fail. The live ones check what the
model *actually received* (it must quote the injected text), with negative controls. Live
steps need `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY`, and GNU `timeout`. Results go
to `demo/last-run.jsonl`. CI runs the offline demo on Linux and macOS.

## Alternative installs

```bash
claude --plugin-dir /path/to/clafra                 # one session only
ln -s /path/to/clafra ~/.claude/skills/clafra       # always loaded, as clafra@skills-dir
```

## License

MIT. See [LICENSE](LICENSE).
