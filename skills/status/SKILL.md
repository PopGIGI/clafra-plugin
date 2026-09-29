---
name: status
description: Show clafra governance status for this repo — which governed skills are active or stale, why, and any unreviewed maintenance reviews. Use when the user asks "clafra status", "are my skills stale", "what did governance flag", or at the start of work on a governed repo.
---

# clafra status

Run `clafra status` from the repo root and report the result.

- For each stale skill, state the exact reason line (missing path, failed check, stack change).
- Do not fix stale skills silently. Offer: update the skill's `clafra.json` (if the fix is unambiguous, e.g. a renamed path), or deprecate it (`/clafra:deprecate`).
- If there are unreviewed reviews, summarize them and ask before running `clafra ack`.
