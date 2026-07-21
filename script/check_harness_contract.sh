#!/usr/bin/env bash
# check_harness_contract.sh — static lint for a harness participant's read path.
#
# The seeder/reader contract is documented in
# docs/runbooks/new-harness-integration.md but was, until VEN-1398, enforced by
# nothing. That matters because every way of getting it wrong fails SILENTLY: a
# predicate missing a tier still returns a valid, non-empty result set. The query
# succeeds, the hook prints rules, everything looks healthy — and an entire tier
# of rules never reaches an agent. pamm lost 10 critical Rails rules that way
# (VEN-1392) and nobody noticed until an unrelated audit tripped over it.
#
# This is the cheap half of the check: pure text, no database, milliseconds. Run
# it in the participant's own CI.
#
#   Usage: script/check_harness_contract.sh [repo-root]   (default: cwd)
#
# Exits 0 if the read path is well-formed, 1 with a diagnosis otherwise.
set -uo pipefail

ROOT="${1:-$(pwd)}"
cd "$ROOT" || { echo "check_harness_contract: no such directory: $ROOT" >&2; exit 1; }

FAIL=0
note() { printf '  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAIL=1; }
pass() { printf 'ok    %s\n' "$*"; }

echo "harness contract check — ${ROOT}"
echo

# ---------------------------------------------------------------------------
# 1. harness_env.sh must export both discriminators.
#
# HARNESS_APP alone is not enough: readers select the stack tier via
# HARNESS_STACK, so an env file that omits it makes every reader fall back to a
# default that may be silently wrong for this app.
# ---------------------------------------------------------------------------
ENV_FILE="script/lib/harness_env.sh"
if [ ! -f "$ENV_FILE" ]; then
  fail "$ENV_FILE is missing — every reader depends on it"
else
  for var in HARNESS_APP HARNESS_STACK; do
    if grep -qE "^[[:space:]]*export[[:space:]]+${var}=" "$ENV_FILE"; then
      pass "$ENV_FILE exports $var"
    else
      fail "$ENV_FILE never exports $var"
      note "add: export ${var}=\"\${${var}:-<value>}\""
    fi
  done
fi

# ---------------------------------------------------------------------------
# 2. Every reader predicate must include the stack tier.
#
# We look at each line selecting from agent_harness.rules that carries an `app
# IN (...)` predicate, and require a 'global-' tier inside it. This is the exact
# defect VEN-1392 shipped at eight separate sites.
#
# Lines matched but lacking `app IN` are reported separately: a rules query with
# no app predicate at all reads every app's tier, which is a different bug.
# ---------------------------------------------------------------------------
READER_PATHS=(.claude script bin)
EXISTING=()
for p in "${READER_PATHS[@]}"; do [ -e "$p" ] && EXISTING+=("$p"); done

if [ ${#EXISTING[@]} -eq 0 ]; then
  note "no .claude/, script/ or bin/ to scan — nothing to check"
else
  # -I skips binaries; the seeder is excluded because it WRITES one app tier and
  # legitimately carries no multi-tier read predicate.
  MATCHES=$(grep -rInE 'agent_harness\.rules' "${EXISTING[@]}" 2>/dev/null \
            | grep -v 'build_harness_db' \
            | grep -v 'check_harness_contract') || true

  if [ -z "$MATCHES" ]; then
    note "no queries against agent_harness.rules found"
  else
    BAD_TIER=0
    NO_PRED=0
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      loc="${line%%:*}"; rest="${line#*:}"; lineno="${rest%%:*}"

      # A query may span lines: `FROM agent_harness.rules` on one, `WHERE app IN
      # (...)` on the next. Judge the whole window, never a single line — an
      # earlier version of this check looked ahead only to confirm a predicate
      # EXISTED and never inspected its tiers, so it passed three of the eight
      # sites VEN-1392 shipped. Both questions must be asked of the same text.
      window=$(sed -n "${lineno},$((lineno + 3))p" "$loc" 2>/dev/null)
      pred=$(printf '%s' "$window" | grep -E 'app[[:space:]]+IN[[:space:]]*\(' | head -1)

      if [ -n "$pred" ]; then
        if ! printf '%s' "$pred" | grep -q "global-"; then
          fail "${loc}:${lineno} — predicate omits the stack tier"
          note "$(printf '%s' "$pred" | sed 's/^[[:space:]]*//' | cut -c1-100)"
          BAD_TIER=$((BAD_TIER + 1))
        fi
      elif printf '%s' "$window" | grep -qE 'FROM[[:space:]]+agent_harness\.rules'; then
        fail "${loc}:${lineno} — reads agent_harness.rules with no app predicate"
        note "an unfiltered read returns every app's rules, not just this one's"
        NO_PRED=$((NO_PRED + 1))
      fi
    done <<< "$MATCHES"

    TOTAL=$(printf '%s\n' "$MATCHES" | grep -c . )
    if [ "$BAD_TIER" -eq 0 ] && [ "$NO_PRED" -eq 0 ]; then
      pass "all ${TOTAL} agent_harness.rules queries are tier-complete"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 3. A cached rule file must not predate the tiers it claims to cache.
#
# check-rules-loaded.sh reads .claude/.rules-cache BEFORE the DB, so a stale
# cache silently shadows an otherwise-correct reader — the fix lands, the tests
# pass, and agents still see the old rule set (VEN-1392 again).
#
# We cannot diff the cache against the DB without a connection, so the static
# check is narrow: if a cache exists and mentions no stack tier while the
# readers do, it is stale by construction.
# ---------------------------------------------------------------------------
CACHE=".claude/.rules-cache"
if [ -f "$CACHE" ]; then
  STACK=$(grep -oE '^[[:space:]]*export[[:space:]]+HARNESS_STACK="?\$\{HARNESS_STACK:-[a-z]+' "$ENV_FILE" 2>/dev/null \
          | grep -oE '[a-z]+$') || true
  if [ -n "${STACK:-}" ] && ! grep -q "global-${STACK}" "$CACHE" 2>/dev/null; then
    # The cache stores rule text, not app names, so absence of the literal tier
    # name is suggestive rather than conclusive — warn, do not fail.
    note "WARN  $CACHE may predate the global-${STACK} tier"
    note "      regenerate it: script/bootstrap-agent.sh <role>"
  else
    pass "$CACHE looks current"
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "harness contract: OK"
else
  echo "harness contract: FAILED — see above."
  echo "Contract reference: harness-infra/docs/runbooks/new-harness-integration.md"
fi
exit "$FAIL"
