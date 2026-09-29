---
name: deprecate
description: Deprecate a stale governed skill in a clafra repo, moving it to .clafra/deprecated/ with a reason and audit trail. Use when the user says "deprecate/retire/remove skill X" — never delete skill directories directly.
disable-model-invocation: true
---

# clafra deprecate

1. Run `clafra status` and confirm the skill is stale and why.
2. Confirm the reason with the user.
3. Run `clafra deprecate <name> --reason "<reason>"`.
   Only add `--force` (deprecating an active skill) on an explicit user decision.
