---
name: review
description: Run or read clafra's artifact-grounded maintenance review — mechanical facts gathered in pure code, then an LLM proposes fixes/deprecations that must cite those facts verbatim. Use when the user asks for a "clafra review", "governance review", or to process pending reviews.
---

# clafra review

- Facts only (no LLM): `clafra gather`
- Full review: `clafra review [--model <id>]` → writes `.clafra/reviews/<ts>.json`
- Findings whose `evidence` is not verbatim in the facts are moved to `uncited_dropped` automatically.

Present `fixes` and `deprecation_candidates` to the user. Apply a fix by editing that skill's `clafra.json`, then run `clafra validate`. Mark done with `clafra ack` only after the user has seen them.
