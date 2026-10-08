# Changelog

## Unreleased

- **Fix:** change detection dropped the first character of the first `git status` path when
  that file had unstaged changes (` M path`, whose leading space was stripped), so that file
  was invisible to the end-of-turn check and to incremental validation. `git status` is now
  read NUL-delimited (`-z`), which also handles quoted paths and both sides of a rename.
- **Fix:** the end-of-turn hook logged `pass` for untrusted skills whose checks it never ran;
  it now logs `skipped (untrusted)`.

## 0.2.0 — 2026-10-07

First public release.

- **Trust gate:** check and generator commands run only after a human approves them with
  `clafra trust` in an interactive terminal; approvals live in `~/.config/clafra/trust.json`.
  Notices now print the full command to run.
- **Generated blocks:** `clafra sync` rewrites only `<!-- clafra:begin NAME -->` blocks from
  generators declared in `clafra.json`; hand-edited or out-of-date blocks fail validation.
- **Read-time rules + end-of-turn check** replace the edit-time hook: skills compile to
  path-scoped `.claude/rules/clafra-<skill>.md`; the `Stop` hook re-checks skills whose files
  changed during the session.
- Incremental validation (`validate --full` forces all); `staleness_days` before deprecation
  is proposed.
- Nightly `clafra-cron` runs `validate --full` only (no LLM); `clafra review` is on demand.
- Packaging: MIT license, marketplace manifest, CI running the offline demo on Linux and macOS.

## 0.1.0 — 2026-09-29

Initial plugin: governed skills (`SKILL.md` + `clafra.json`), creation guard, drift detection,
deprecation with audit trail, artifact-grounded maintenance review.
