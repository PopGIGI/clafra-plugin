# clafra (plugin)

Skill lifecycle governance for Claude Code, as a native plugin. Supersedes
`/home/pop/clafra` (bash scripts copied per repo) and `/home/pop/clafra-pm`.

Governed skills are ordinary Claude Code skills — `.claude/skills/<name>/SKILL.md` —
plus a tracked `clafra.json` sidecar that says what the skill depends on and how to
tell when it has stopped being true:

```json
{
  "intent": "Compute order fees with Decimal money and banker's rounding via apply_fee",
  "watches": ["src/fees.py"],
  "checks": ["grep -q 'ROUND_HALF_EVEN' src/fees.py", "cd src && python3 -c '...assert apply_fee(D(\"10.00\")) == D(\"10.25\")'"],
  "stack_dependencies": ["requirements.txt"],
  "evidence": ["session:a", "session:b", "session:c"],
  "staleness_days": 30
}
```

Runtime state (status, last validated commit) lives in `.clafra/state.json`, which is
gitignored, so validation never dirties the repo. `.clafra/audit.log` and
`.clafra/deprecated/` are the audit trail and stay tracked.

## What it does

| Mechanism | How | Proven by demo scenario |
|---|---|---|
| Read-time context | each skill compiles to a generated, gitignored `.claude/rules/clafra-<skill>.md` scoped to its `watches`; Claude Code loads it natively when Claude **reads** (or edits) a matching file, i.e. while planning. Stale skills' rules say STALE | 1 |
| End-of-turn check | `SessionStart` records a baseline (HEAD + hash of dirty files); the `Stop` hook re-runs checks of skills whose files changed this session — by any means, including Bash — and sends Claude back once to fix the code or update the skill | 4c |
| Drift at session start | `SessionStart` hook runs `clafra validate` (incremental: a skill's checks re-run only when its watched / check-referenced / stack / skill files changed; `--full` forces all); stale skills are injected as context | 2, 4b |
| Deprecation proposal | a skill stale longer than its `staleness_days` (default 30) is flagged "propose deprecation" | 6 |
| Maintenance review (on demand) | `clafra gather` (pure code) → `claude -p --json-schema` → findings must cite an **exact** fact atom or are dropped | 3 |
| Creation guard | `clafra create`: overlap ≥0.7 blocked, 0.4–0.7 needs a human decision, <3 evidence refs blocked, checks must pass at birth | 5 |
| Deprecation | `clafra deprecate`: stale only (unless `--force`), moved to `.clafra/deprecated/` with `deprecation.json` | 6 |

Plugin skills: `/clafra:status`, `/clafra:create`, `/clafra:review`, `/clafra:deprecate`
(user-invoked only). `bin/clafra` is on the Bash PATH while the plugin is loaded.

## Demo

```bash
demo/demo.sh --offline   # 40 mechanical assertions, no model calls
demo/demo.sh             # + 9 live assertions via claude -p (haiku), isolated HOME
```

Copies `demo/fixture/` (a tiny fee calculator with two governed skills) to a temp
repo, then runs six scenarios. Every assertion can fail — the live ones check what the
model *actually received* (it must quote the injected text), with negative controls.
Results go to `demo/last-run.jsonl`.

## Install

```bash
ln -s /home/pop/clafra-plugin ~/.claude/skills/clafra   # auto-loads everywhere as clafra@skills-dir
claude --plugin-dir /home/pop/clafra-plugin              # or: one session only
```

Hooks are no-ops in repos without governed skills.

## Scheduled review

`bin/clafra-cron` runs `clafra validate --full` (every check, no cache, **no LLM**) for each
repo in `~/.config/clafra/repos` (one path per line). Results land in each repo's
`.clafra/state.json`, so stale skills surface at the next session start and in the
read-time rules. Repos are isolated from each other.

```
17 3 * * * /home/pop/clafra-plugin/bin/clafra-cron >> /home/pop/.local/state/clafra/cron.log 2>&1
```

`clafra review` (LLM proposals over gathered facts, must cite exact facts) remains available
on demand but is no longer scheduled: incremental validation + the end-of-turn check catch
drift as it happens, and the scheduled LLM pass never produced a useful finding.

## Carried over vs dropped

| From | Kept as | Dropped (why) |
|---|---|---|
| clafra `tools/*.json` | `SKILL.md` + `clafra.json` | JSON-only tools Claude never loaded |
| clafra `summon.sh` | generated path-scoped rules (read time) | plain stdout never reached the model; edit time was after planning |
| clafra `validate.sh --session-start` | `SessionStart` hook | "remember to run it" instruction in CLAUDE.md |
| clafra `cron-gather` / `cron-dispatch` | `gather` / `review` | hand-parsed LLM JSON → `--json-schema`; substring citing → exact atoms |
| clafra `create-tool.sh`, similarity-local | `create`, `overlap` | SSH remote similarity tier (never configured) |
| clafra `deprecate.sh` | `deprecate` | — |
| clafra `parse-log` / pattern mining | — (for now) | produced noise; read newest log across *all* projects |
| clafra-pm capture ledger, permission graduation, slots | — | auto mode + `/fewer-permission-prompts` cover permissions; slots ran twice |

## Not done yet

- `claude plugin eval` suite — needs a newer CLI than the installed 2.1.195.
- Pattern mining that yields real candidates (evidence refs are manual today).
