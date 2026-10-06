#!/usr/bin/env bash
# demo.sh — prove clafra's claims end-to-end on a throwaway copy of demo/fixture.
#
# Every scenario asserts on observable evidence (exit codes, files, hook JSON, and
# what the model actually received). Each assertion is written so it CAN fail.
#
# Usage: demo/demo.sh [--offline] [--keep] [--model <id>]
#   --offline   skip live `claude -p` steps (mechanical assertions only, $0)
#   --keep      keep the work dir for inspection
# Live steps run with an isolated HOME (no user CLAUDE.md, hooks or plugins) and
# need CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY; ~/.claude/clafra-env is
# sourced if present.

set -uo pipefail

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
CLAFRA="$PLUGIN/bin/clafra"
MODEL="claude-haiku-4-5-20251001"
LIVE=1 KEEP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --offline) LIVE=0 ;;
        --keep) KEEP=1 ;;
        --model) MODEL="$2"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 64 ;;
    esac
    shift
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/clafra-demo.XXXXXX")"
REPORT="$WORK/demo-report.jsonl"
PASS=0 FAIL=0 SKIP=0
[[ $KEEP -eq 1 ]] || trap 'rm -rf "$WORK"' EXIT

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
record() { # scenario claim result evidence
    printf '%s\n' "$(jq -cn --arg s "$1" --arg c "$2" --arg r "$3" --arg e "$4" \
        '{scenario:$s, claim:$c, result:$r, evidence:$e}')" >> "$REPORT"
    case "$3" in
        PASS) PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$2" ;;
        FAIL) FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n       %s\n' "$2" "${4:0:400}" ;;
        SKIP) SKIP=$((SKIP + 1)); printf '  \033[33mSKIP\033[0m %s\n' "$2" ;;
    esac
}
check() { # scenario claim evidence command...
    local s="$1" c="$2" e="$3"; shift 3
    if "$@" >/dev/null 2>&1; then record "$s" "$c" PASS "$e"; else record "$s" "$c" FAIL "$e"; fi
}
expect_rc() { # scenario claim expected-rc command...
    local s="$1" c="$2" want="$3"; shift 3
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if [[ $rc -eq $want ]]; then record "$s" "$c" PASS "rc=$rc: $out"; else record "$s" "$c" FAIL "rc=$rc (want $want): $out"; fi
    LAST_OUT="$out"
}

# Live model call: fresh HOME, plugin loaded via --plugin-dir, cwd = fixture.
ask() {
    ( cd "$REPO" && HOME="$WORK/home" timeout 240 claude -p "$1" --model "$MODEL" \
        --plugin-dir "$PLUGIN" --allowedTools "Edit Read" --max-budget-usd 0.50 < /dev/null 2>&1 )
}

# ------------------------------------------------------------------ setup
if [[ $LIVE -eq 1 ]]; then
    if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}${ANTHROPIC_API_KEY:-}" && -f "$HOME/.claude/clafra-env" ]]; then
        set -a; . "$HOME/.claude/clafra-env"; set +a
    fi
    if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}${ANTHROPIC_API_KEY:-}" ]] || ! command -v claude >/dev/null; then
        echo "no claude auth/CLI — running offline" >&2; LIVE=0
    fi
fi
REPO="$WORK/shopcalc"
mkdir -p "$WORK/home"
cp -r "$PLUGIN/demo/fixture" "$REPO"
cd "$REPO" || exit 1
git init -q && git add -A && git -c user.name=demo -c user.email=demo@local commit -qm "fixture"
export CLAFRA_ROOT="$REPO"
export CLAFRA_TRUST_FILE="$WORK/trust.json"     # never touch the real ~/.config/clafra/trust.json
# Stand-in for the human typing 'yes' at `clafra trust` in their own terminal. `script`
# fakes a TTY, which is exactly why the README pairs trust with permission deny rules.
approve() { ( cd "${1:-$REPO}" && CLAFRA_ROOT="${1:-$REPO}" script -qec "$CLAFRA trust" /dev/null <<<"yes" >/dev/null ); }
approve
jq -n --arg c "$(git rev-parse HEAD)" '{last_commit:$c}' > .clafra/review-state.json
echo "work dir: $WORK   live: $LIVE   model: $MODEL"

# ------------------------------------------------------------------ 1. context
bold "1. Read-time context — a skill's constraints load as soon as Claude reads a watched file"
S=context
RULE=.claude/rules/clafra-fee-calc.md
check $S "validate generated a path-scoped rule for fee-calc" "$(cat "$RULE" 2>/dev/null)" \
    bash -c 'grep -qx "  - \"src/fees.py\"" "$0" && grep -q "clafra\[fee-calc\]" "$0"' "$RULE"
check $S "generated rules are gitignored" "$(git check-ignore -v "$RULE")" git check-ignore -q "$RULE"
check $S "no rule for an unwatched file" "$(ls .claude/rules)" bash -c '! grep -l "src/report.py" .claude/rules/clafra-*.md'

if [[ $LIVE -eq 1 ]]; then
    Q='Do not edit anything. Then quote verbatim every line beginning with "clafra[" present in your context from any source. If there are none, answer exactly NO-CLAFRA-CONTEXT.'
    out="$(ask "Use the Read tool on src/fees.py. $Q")"
    check $S "live: just READING src/fees.py brings in clafra[fee-calc]" "$out" grep -q 'clafra\[fee-calc\]' <<<"$out"
    out="$(ask "Use the Read tool on src/report.py. $Q")"
    check $S "live control: reading unwatched src/report.py brings in nothing" "$out" grep -q 'NO-CLAFRA-CONTEXT' <<<"$out"
else
    record $S "live: model receives context on read" SKIP "offline"
fi

# ------------------------------------------------------------------ 2. drift
bold "2. Drift — renaming/deleting what a skill depends on makes it stale at next session start"
S=drift
git mv src/fees.py src/billing.py
sed -i 's/^from fees import/from billing import/' src/orders.py
git rm -q src/legacy_export.py
git -c user.name=demo -c user.email=demo@local commit -qam "rename fees -> billing, drop legacy export"
expect_rc $S "validate exits 1 after the refactor" 1 "$CLAFRA" validate
check $S "fee-calc flagged: watched path missing: src/fees.py" "$LAST_OUT" grep -q 'watched path missing: src/fees.py' <<<"$LAST_OUT"
check $S "legacy-export flagged stale" "$LAST_OUT" grep -q 'legacy-export: stale' <<<"$LAST_OUT"
check $S "fee-calc's read-time rule now says STALE" "$(grep STALE "$RULE")" grep -q 'STALE since' "$RULE"
ss="$(jq -cn --arg c "$REPO" '{hook_event_name:"SessionStart",cwd:$c}' | "$CLAFRA" hook session-start)"
check $S "SessionStart hook emits STALE notice as additionalContext" "$ss" \
    bash -c 'jq -e ".hookSpecificOutput.additionalContext | test(\"fee-calc.*STALE\")" <<<"$0"' "$ss"
if [[ $LIVE -eq 1 ]]; then
    out="$(ask 'Without using any tools: quote verbatim any "clafra governance" notice you received at session start. If none, answer exactly NO-CLAFRA-NOTICE.')"
    check $S "live: model received the session-start stale notice" "$out" grep -Eq "fee-calc.{0,20}STALE" <<<"$out"
else
    record $S "live: model receives session-start notice" SKIP "offline"
fi

# ------------------------------------------------------------------ 3. review
bold "3. Maintenance review — LLM proposes fixes that must cite mechanically gathered facts"
S=review
facts="$("$CLAFRA" gather)"
check $S "gather (no LLM) records the rename src/fees.py -> src/billing.py" "$(jq -c .renames <<<"$facts")" \
    bash -c 'jq -e ".renames[] | select(.old_path==\"src/fees.py\" and .new_path==\"src/billing.py\")" <<<"$0"' "$facts"
atoms="$(jq -c '[.renames[].fact, .deleted[], .skills[].failures[]]' <<<"$facts")"
cp .clafra/review-state.json "$WORK/review-state.bak"
rpath="$(CLAFRA_CLAUDE="$PLUGIN/demo/stub-claude" "$CLAFRA" review 2>&1 | tail -1)"
stub="$(cat "$REPO/$rpath" 2>/dev/null)"
check $S "stub LLM: finding citing an exact fact is kept" "$(jq -c .fixes <<<"$stub")" \
    bash -c 'jq -e ".fixes | length == 1" <<<"$0"' "$stub"
check $S "stub LLM: uncited finding ('fee logic looks outdated') is dropped" "$(jq -c .uncited_dropped <<<"$stub")" \
    bash -c 'jq -e "(.deprecation_candidates | length == 0) and (.uncited_dropped[0].evidence == \"fee logic looks outdated\")" <<<"$0"' "$stub"
rm -f "$REPO/$rpath"; cp "$WORK/review-state.bak" .clafra/review-state.json
if [[ $LIVE -eq 1 ]]; then
    rpath="$("$CLAFRA" review --model "$MODEL" 2>&1 | tail -1)"
    review="$(cat "$REPO/$rpath" 2>/dev/null)"
    check $S "review returns schema-valid structured output" "$rpath" \
        bash -c 'jq -e "has(\"fixes\") and has(\"deprecation_candidates\") and (.pending|not)" <<<"$0"' "$review"
    check $S "review proposes fee-calc watches: src/fees.py -> src/billing.py" "$(jq -c .fixes <<<"$review")" \
        bash -c 'jq -e ".fixes[] | select(.skill==\"fee-calc\" and (.new|test(\"src/billing.py\")))" <<<"$0"' "$review"
    check $S "review names legacy-export as a deprecation candidate" "$(jq -c .deprecation_candidates <<<"$review")" \
        bash -c 'jq -e ".deprecation_candidates[] | select(.skill==\"legacy-export\")" <<<"$0"' "$review"
    check $S "every kept finding cites an exact fact atom" "$(jq -c '[.fixes[].evidence, .deprecation_candidates[].evidence]' <<<"$review") ⊆ $atoms" \
        bash -c 'jq -e --argjson a "$1" "[.fixes[].evidence, .deprecation_candidates[].evidence] | all(. as \$e | \$a | index([\$e]))" <<<"$0"' "$review" "$atoms"
else
    record $S "live: LLM review" SKIP "offline"
fi

# ------------------------------------------------------------------ 4. repair
bold "4. Repair — applying the unambiguous fix restores the skill"
S=repair
tmp="$(mktemp)"
jq '.watches = ["src/billing.py"] | .checks |= map(gsub("src/fees.py"; "src/billing.py") | gsub("from fees import"; "from billing import"))' \
    .claude/skills/fee-calc/clafra.json > "$tmp" && mv "$tmp" .claude/skills/fee-calc/clafra.json
"$CLAFRA" validate > "$WORK/v.txt"
check $S "a repaired (changed) check is untrusted until approved" "$(cat "$WORK/v.txt")" grep -q '? fee-calc: untrusted' "$WORK/v.txt"
approve   # the human reviews and approves the repaired check
"$CLAFRA" validate > "$WORK/v.txt"
check $S "fee-calc is active again after the fix" "$(cat "$WORK/v.txt")" grep -q '✓ fee-calc: active' "$WORK/v.txt"
check $S "validation leaves tracked files clean except the intended fix" "$(git status --porcelain)" \
    bash -c '[[ "$(git status --porcelain -- . ":!.clafra" ":!.claude/rules" ":!.claude/skills/fee-calc/clafra.json")" == "" ]]'
git -c user.name=demo -c user.email=demo@local commit -qam "fee-calc: follow rename" && git add .clafra && git -c user.name=demo -c user.email=demo@local commit -qm "clafra audit trail" >/dev/null

# ------------------------------------------------------------------ 4b. incremental validation
bold "4b. Incremental validation — checks re-run only when a skill's own files change"
S=cache
"$CLAFRA" validate >/dev/null   # settle after the commit above (clafra.json changed)
"$CLAFRA" validate > "$WORK/v.txt"
check $S "unchanged skill is served from cache" "$(cat "$WORK/v.txt")" grep -q '✓ fee-calc: active (cached)' "$WORK/v.txt"
echo "# touched" >> src/report.py
"$CLAFRA" validate > "$WORK/v.txt"
check $S "editing an unrelated file keeps the cache" "$(cat "$WORK/v.txt")" grep -q '✓ fee-calc: active (cached)' "$WORK/v.txt"
sed -i 's/rounding=ROUND_HALF_EVEN)/rounding=ROUND_HALF_UP)/' src/billing.py
"$CLAFRA" validate > "$WORK/v.txt"
check $S "uncommitted break in a watched file invalidates the cache (stale)" "$(cat "$WORK/v.txt")" grep -q '✗ fee-calc: stale' "$WORK/v.txt"
git checkout -q -- src/
"$CLAFRA" validate > "$WORK/v.txt"
check $S "reverting restores active (re-checked, not cached)" "$(cat "$WORK/v.txt")" grep -qx '✓ fee-calc: active' "$WORK/v.txt"
"$CLAFRA" validate --full > "$WORK/v.txt"
check $S "--full re-runs every check" "$(cat "$WORK/v.txt")" bash -c '! grep -q cached "$0"' "$WORK/v.txt"

# ------------------------------------------------------------------ 4c. end-of-turn check
bold "4c. End-of-turn check — breaking a governed file sends Claude back before it can finish"
S=stop
SID=demo-offline
ev() { jq -cn --arg c "$REPO" --arg s "$SID" --argjson a "$1" '{hook_event_name:"Stop",cwd:$c,session_id:$s,stop_hook_active:$a}'; }
jq -cn --arg c "$REPO" --arg s "$SID" '{hook_event_name:"SessionStart",cwd:$c,session_id:$s}' | "$CLAFRA" hook session-start >/dev/null
out="$(ev false | "$CLAFRA" hook stop)"
check $S "nothing changed: stop is silent" "out='$out'" test -z "$out"
echo "# note" >> src/report.py
out="$(ev false | "$CLAFRA" hook stop)"
check $S "unrelated file changed: stop is silent" "out='$out'" test -z "$out"
sed -i 's/Decimal("0.025")/Decimal("0.03")/' src/billing.py      # via sed: no Edit tool involved
out="$(ev false | "$CLAFRA" hook stop)"
check $S "watched file broken via sed: stop blocks, naming fee-calc" "$out" \
    bash -c 'jq -e "(.decision == \"block\") and (.reason | test(\"fee-calc\"))" <<<"$0"' "$out"
out="$(ev true | "$CLAFRA" hook stop)"
check $S "second stop in the same turn: warning only (no loop)" "$out" \
    bash -c 'jq -e "(has(\"decision\") | not) and (.systemMessage | test(\"fee-calc\"))" <<<"$0"' "$out"
out="$(ev false | "$CLAFRA" hook stop)"
check $S "same unchanged failure on a later turn is not re-blocked" "$out" \
    bash -c 'jq -e "has(\"decision\") | not" <<<"$0"' "$out"
check $S "read-time rule marks fee-calc STALE mid-session" "$(grep STALE "$RULE")" grep -q 'STALE since' "$RULE"
git checkout -q -- src/
out="$(ev false | "$CLAFRA" hook stop)"
check $S "after revert: stop is silent" "out='$out'" test -z "$out"
check $S "after revert: rule no longer STALE" "$(grep -c STALE "$RULE")" bash -c '! grep -q STALE "$0"' "$RULE"

if [[ $LIVE -eq 1 ]]; then
    : > .clafra/stop.log
    out="$(ask 'In src/billing.py change DEFAULT_RATE to Decimal("0.03") using the Edit tool.')"
    check $S "live: the end-of-turn hook blocked the breaking edit" "$(cat .clafra/stop.log)" grep -q 'block | fee-calc' .clafra/stop.log
    check $S "live: Claude resolved it (checks pass again, or it reports the rule change)" "$out" \
        bash -c '"$1" validate --full >/dev/null || grep -qi "fee-calc" <<<"$0"' "$out" "$CLAFRA"
    git checkout -q -- src/ .claude/skills/
    "$CLAFRA" validate >/dev/null
else
    record $S "live: end-of-turn block" SKIP "offline"
fi

# ------------------------------------------------------------------ 5. creation guard
bold "5. Creation guard — overlap, evidence threshold and verifiable checks are enforced"
S=create
expect_rc $S "near-duplicate of fee-calc is blocked (exit 2)" 2 "$CLAFRA" create --name fee-calculator \
    --intent "Compute order fees with Decimal money and rounding via apply_fee" --watch src/billing.py \
    --check "true" --evidence a --evidence b --evidence c
expect_rc $S "pattern seen in fewer than 3 sessions is blocked (exit 4)" 4 "$CLAFRA" create --name order-totals \
    --intent "Sum order line items into a total before fees" --watch src/orders.py \
    --check "grep -q 'def order_total' src/orders.py" --evidence session:x
expect_rc $S "skill whose check fails at birth is blocked (exit 5)" 5 "$CLAFRA" create --name order-totals \
    --intent "Sum order line items into a total before fees" --watch src/orders.py \
    --check "grep -q 'def does_not_exist' src/orders.py" --evidence x --evidence y --evidence z
expect_rc $S "distinct, evidenced, verifiable skill is created (exit 0)" 0 "$CLAFRA" create --name order-totals \
    --intent "Sum order line items into a total before fees" --watch src/orders.py \
    --check "grep -q 'def order_total' src/orders.py" --evidence x --evidence y --evidence z
"$CLAFRA" validate > "$WORK/v.txt"
check $S "a newly created skill's checks don't run until approved" "$(cat "$WORK/v.txt")" grep -q '? order-totals: untrusted' "$WORK/v.txt"
approve
check $S "created as a native skill (SKILL.md frontmatter name)" "$(head -3 .claude/skills/order-totals/SKILL.md 2>/dev/null)" \
    grep -q '^name: order-totals$' .claude/skills/order-totals/SKILL.md
check $S "audit.log records both blocks and the creation" "$(cat .clafra/audit.log)" \
    bash -c 'grep -q "create-blocked | fee-calculator" .clafra/audit.log && grep -q "created | order-totals" .clafra/audit.log'

# ------------------------------------------------------------------ 6. deprecation
bold "6. Deprecation — only stale skills are retired, with an audit trail"
S=deprecate
expect_rc $S "deprecating an active skill is refused (exit 2)" 2 "$CLAFRA" deprecate fee-calc --reason "demo"
tmp="$(mktemp)"
jq --arg t "$(date -u -d '40 days ago' +%Y-%m-%dT%H:%M:%SZ)" '.skills["legacy-export"].stale_since = $t' .clafra/state.json > "$tmp" && mv "$tmp" .clafra/state.json
"$CLAFRA" validate > "$WORK/v.txt"
check $S "skill stale past its staleness_days (30) is flagged for deprecation" "$(cat "$WORK/v.txt")" \
    grep -q 'stale for 40 days (limit 30): propose deprecation' "$WORK/v.txt"
ss="$(jq -cn --arg c "$REPO" '{hook_event_name:"SessionStart",cwd:$c}' | "$CLAFRA" hook session-start)"
check $S "session-start notice carries the deprecation proposal" "$ss" \
    bash -c 'jq -e ".hookSpecificOutput.additionalContext | test(\"legacy-export.*propose deprecation\")" <<<"$0"' "$ss"
expect_rc $S "stale legacy-export is deprecated (exit 0)" 0 "$CLAFRA" deprecate legacy-export --reason "legacy CSV export removed in refactor"
dep="$(ls -d .clafra/deprecated/legacy-export-* 2>/dev/null | head -1)"
check $S "archived with deprecation.json (reason + stale reasons)" "$(cat "$dep/deprecation.json" 2>/dev/null)" \
    jq -e '.reason and (.stale_reasons | length > 0)' "$dep/deprecation.json"
check $S "no longer discoverable in .claude/skills/" "$(ls .claude/skills)" test ! -e .claude/skills/legacy-export
check $S "its read-time rule is removed; the new skill's rule exists" "$(ls .claude/rules)" \
    bash -c 'test ! -e .claude/rules/clafra-legacy-export.md && test -e .claude/rules/clafra-order-totals.md'
expect_rc $S "repo validates clean afterwards (exit 0)" 0 "$CLAFRA" validate

# ------------------------------------------------------------------ 7. trust
bold "7. Trust — check commands run only after a human approves them in a terminal"
S=trust
U="$WORK/cloned"; CANARY="$WORK/canary"
cp -r "$PLUGIN/demo/fixture" "$U"
jq --arg c "touch $CANARY" '.checks += [$c]' "$U/.claude/skills/fee-calc/clafra.json" > "$WORK/t.json" \
    && mv "$WORK/t.json" "$U/.claude/skills/fee-calc/clafra.json"
( cd "$U" && git init -q && git add -A && git -c user.name=x -c user.email=x@x commit -qm "someone else's repo" )
ss="$(jq -cn --arg c "$U" '{hook_event_name:"SessionStart",cwd:$c,session_id:"cloned"}' | CLAFRA_ROOT="$U" "$CLAFRA" hook session-start)"
( cd "$U" && CLAFRA_ROOT="$U" "$CLAFRA" validate --full >/dev/null )
check $S "cloned repo: its check commands never ran (canary absent)" "$(ls "$WORK")" test ! -e "$CANARY"
check $S "session start asks the user to approve, not the agent" "$ss" \
    bash -c 'jq -e ".hookSpecificOutput.additionalContext | test(\"repo not trusted.*never run it yourself\")" <<<"$0"' "$ss"
expect_rc $S "clafra trust refuses without an interactive terminal (exit 3)" 3 \
    bash -c 'cd "$1" && echo yes | CLAFRA_ROOT="$1" "$2" trust' _ "$U" "$CLAFRA"
check $S "canary still absent after the refused approval" "$(ls "$WORK")" test ! -e "$CANARY"
approve "$U"
check $S "after a human approves, the checks do run (canary present)" "$(ls "$WORK")" test -e "$CANARY"

SID=demo-trust
jq -cn --arg c "$REPO" --arg s "$SID" '{hook_event_name:"SessionStart",cwd:$c,session_id:$s}' | "$CLAFRA" hook session-start >/dev/null
jq '.checks = ["true"]' .claude/skills/fee-calc/clafra.json > "$WORK/t.json" && mv "$WORK/t.json" .claude/skills/fee-calc/clafra.json
"$CLAFRA" validate > "$WORK/v.txt"
check $S "agent loosens fee-calc's check to 'true': skill becomes untrusted, not green" "$(cat "$WORK/v.txt")" \
    grep -q '? fee-calc: untrusted' "$WORK/v.txt"
check $S "its read-time rule says UNTRUSTED" "$(grep UNTRUSTED "$RULE")" grep -q 'UNTRUSTED: checks changed' "$RULE"
out="$(jq -cn --arg c "$REPO" --arg s "$SID" '{hook_event_name:"Stop",cwd:$c,session_id:$s,stop_hook_active:false}' | "$CLAFRA" hook stop)"
check $S "end of turn: agent is sent back to tell the user (only they can approve)" "$out" \
    bash -c 'jq -e "(.decision == \"block\") and (.reason | test(\"only they can approve\"))" <<<"$0"' "$out"
git checkout -q -- .claude/skills/
"$CLAFRA" validate > "$WORK/v.txt"
check $S "restoring the approved check makes fee-calc trusted and active again" "$(cat "$WORK/v.txt")" \
    grep -q '✓ fee-calc: active' "$WORK/v.txt"

# ------------------------------------------------------------------ 8. generated blocks
bold "8. Generated blocks — doc text derived from code, rewritten only between markers"
S=sync
G="$WORK/gen"; CANARY2="$WORK/canary2"
cp -r "$PLUGIN/demo/fixture" "$G"
mkdir -p "$G/tools"
cat > "$G/tools/fee_rate.py" <<'PY'
import re
rate = re.search(r'DEFAULT_RATE = Decimal\("([0-9.]+)"\)', open("src/fees.py").read()).group(1)
print(f"Default fee rate: {float(rate) * 100:g}%")
PY
printf '# shopcalc\n\nHand-written intro.\n\n<!-- clafra:begin fee-rate -->\nDefault fee rate: (stale)\n<!-- clafra:end fee-rate -->\n\nHand-written footer.\n' > "$G/README.md"
jq '.watches += ["README.md"] | .generate = {"fee-rate": "python3 tools/fee_rate.py"}' \
    "$G/.claude/skills/fee-calc/clafra.json" > "$WORK/t.json" && mv "$WORK/t.json" "$G/.claude/skills/fee-calc/clafra.json"
( cd "$G" && git init -q && git add -A && git -c user.name=x -c user.email=x@x commit -qm gen )
approve "$G"
gv() { ( cd "$G" && CLAFRA_ROOT="$G" "$CLAFRA" "$@" ); }
gv validate > "$WORK/v.txt"
check $S "out-of-date block fails validation" "$(cat "$WORK/v.txt")" grep -q "generated block '\*' in README.md is out of date" "$WORK/v.txt"
expect_rc $S "sync --check reports it and writes nothing (exit 1)" 1 bash -c 'cd "$1" && CLAFRA_ROOT="$1" "$2" sync --check' _ "$G" "$CLAFRA"
cp "$G/README.md" "$WORK/readme.before"
expect_rc $S "sync regenerates the block (exit 0)" 0 bash -c 'cd "$1" && CLAFRA_ROOT="$1" "$2" sync' _ "$G" "$CLAFRA"
check $S "block now derived from code: 'Default fee rate: 2.5%'" "$(cat "$G/README.md")" grep -qx 'Default fee rate: 2.5%' "$G/README.md"
check $S "every byte outside the markers is unchanged" "$(diff "$WORK/readme.before" "$G/README.md")" \
    bash -c 'diff <(sed "/clafra:begin/,/clafra:end/d" "$0") <(sed "/clafra:begin/,/clafra:end/d" "$1")' "$WORK/readme.before" "$G/README.md"
gv validate > "$WORK/v.txt"
check $S "validates active once in sync" "$(cat "$WORK/v.txt")" grep -q '✓ fee-calc: active' "$WORK/v.txt"
sed -i 's/Decimal("0.025")/Decimal("0.03")/' "$G/src/fees.py"
gv validate > "$WORK/v.txt"
check $S "code changes, doc can't silently disagree: block flagged out of date" "$(cat "$WORK/v.txt")" grep -q "generated block .* out of date" "$WORK/v.txt"
gv sync >/dev/null
check $S "sync follows the code: 'Default fee rate: 3%'" "$(grep 'fee rate' "$G/README.md")" grep -qx 'Default fee rate: 3%' "$G/README.md"
( cd "$G" && git checkout -q -- src/ README.md )
gv sync >/dev/null; sed -i 's/^Default fee rate: 2.5%$/Default fee rate: 0% (hand-edited)/' "$G/README.md"
gv validate > "$WORK/v.txt"
check $S "hand-editing inside the block is caught" "$(cat "$WORK/v.txt")" grep -q "out of date" "$WORK/v.txt"
gv sync >/dev/null
printf '\n<!-- clafra:begin evil -->\nx\n<!-- clafra:end evil -->\n' >> "$G/README.md"; cp "$G/README.md" "$WORK/readme.evil"
expect_rc $S "a marker naming an undeclared generator: sync refuses (exit 2)" 2 bash -c 'cd "$1" && CLAFRA_ROOT="$1" "$2" sync' _ "$G" "$CLAFRA"
check $S "...and the doc is left untouched" "" cmp -s "$WORK/readme.evil" "$G/README.md"
( cd "$G" && git checkout -q -- README.md ) && gv sync >/dev/null
jq --arg c "touch $CANARY2; python3 tools/fee_rate.py" '.generate["fee-rate"] = $c' "$G/.claude/skills/fee-calc/clafra.json" > "$WORK/t.json" \
    && mv "$WORK/t.json" "$G/.claude/skills/fee-calc/clafra.json"
gv sync > "$WORK/v.txt"; gv validate >> "$WORK/v.txt"
check $S "a changed generator command is untrusted: not run until approved" "$(cat "$WORK/v.txt")" \
    bash -c 'grep -q "fee-calc: untrusted" "$0" && test ! -e "$1"' "$WORK/v.txt" "$CANARY2"
jq '.generate["fee-rate"] = "echo \"<!-- clafra:end fee-rate -->injected\""' "$G/.claude/skills/fee-calc/clafra.json" > "$WORK/t.json" \
    && mv "$WORK/t.json" "$G/.claude/skills/fee-calc/clafra.json"
approve "$G"; cp "$G/README.md" "$WORK/readme.pre"
gv sync > "$WORK/v.txt"
check $S "generator output containing markers is refused, doc untouched" "$(cat "$WORK/v.txt")" \
    bash -c 'grep -q "contains clafra markers" "$0" && cmp -s "$1" "$2"' "$WORK/v.txt" "$WORK/readme.pre" "$G/README.md"

# ------------------------------------------------------------------ summary
bold "Result: $PASS passed, $FAIL failed, $SKIP skipped"
cp "$REPORT" "$PLUGIN/demo/last-run.jsonl"
echo "report: $PLUGIN/demo/last-run.jsonl"
[[ $FAIL -eq 0 ]]
