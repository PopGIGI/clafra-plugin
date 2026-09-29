---
name: create
description: Create a new governed project skill under clafra's creation rules (3-session evidence threshold, overlap guard, success checks required). Use whenever the user or you want to turn a recurring pattern into a skill in a clafra-governed repo — never write .claude/skills/*/ by hand there.
---

# clafra create

Governed skills live in `.claude/skills/<name>/` as a native `SKILL.md` plus a `clafra.json` sidecar. Only create them through the CLI:

1. Score the intent first: `clafra overlap "<one-sentence intent>"`.
   - score ≥ 0.7 → do not create; propose extending the matching skill.
   - 0.4–0.7 → ask the user; only pass `--confirm-distinct "<why>"` on their decision.
2. Collect evidence: at least 3 distinct session references where the pattern recurred.
3. Write at least one `--check` (a shell command, run from repo root, exit 0 = holds) that would **fail** if the skill's assumptions broke. `grep -q 'word' file` that can never fail is not a check.
4. Run:
   ```
   clafra create --name <kebab-name> --intent "<intent>" \
     --watch <path-or-glob> [--watch ...] --check "<cmd>" [--check ...] \
     --evidence <ref> --evidence <ref> --evidence <ref> [--stack-dep <file>] \
     [--description "<when Claude should use it>"] [--body "<SKILL.md body>"]
   ```
Exit codes: 2 overlap block, 3 ambiguous, 4 below threshold, 5 missing/failing checks. Report the refusal verbatim; do not work around it.
