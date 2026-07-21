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
# The app's own discriminators, so we can check the tier a reader names is the
# tier this app should actually be reading. A rails app selecting 'global-godot'
# is exactly the silent-wrong-tier failure this script exists to catch, and an
# earlier version passed it because it only grepped for the literal "global-".
STACK=$(sed -nE 's/^[[:space:]]*export[[:space:]]+HARNESS_STACK=.*:-([a-z-]+).*/\1/p' "$ENV_FILE" 2>/dev/null | head -1)
APPNAME=$(sed -nE 's/^[[:space:]]*export[[:space:]]+HARNESS_APP=.*:-([a-z_-]+).*/\1/p' "$ENV_FILE" 2>/dev/null | head -1)

READER_FILES=$(find .claude script bin lib -type f \( -name '*.sh' -o -name '*.bash' -o -name '*.rb' \) 2>/dev/null \
               | grep -v '/build_harness_db' \
               | grep -v '/check_harness_contract' \
               | sort) || true

if [ -z "$READER_FILES" ]; then
  note "no reader scripts found under .claude/, script/, bin/ or lib/"
else
  BAD=0
  SEEN=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue

    # Statement-oriented, not line-oriented. Strip comments first (a `global-`
    # inside a comment must not satisfy the check), collapse the file to one
    # line, then cut it into statements at `;`. Every statement mentioning
    # agent_harness.rules is then judged as a whole, so a predicate any distance
    # below its FROM is still found — the previous fixed 4-line lookahead both
    # missed distant predicates and falsely failed correct ones.
    statements=$(sed -e 's/[[:space:]]#[^"'"'"']*$//' -e 's/^[[:space:]]*#.*$//' -e 's|--[^"'"'"']*$||' "$f" 2>/dev/null \
                 | tr '\n' ' ' | tr ';' '\n' | grep 'agent_harness\.rules') || true
    [ -z "$statements" ] && continue

    while IFS= read -r st; do
      [ -z "$st" ] && continue
      SEEN=$((SEEN + 1))
      short=$(printf '%s' "$st" | sed 's/^[[:space:]]*//' | tr -s ' ' | cut -c1-100)

      # Accept either `app IN (...)` or `app = ANY(ARRAY[...])`.
      if ! printf '%s' "$st" | grep -qE 'app[[:space:]]*(IN[[:space:]]*\(|=[[:space:]]*ANY)'; then
        fail "${f} — reads agent_harness.rules with no app predicate"
        note "$short"
        note "an unfiltered read returns every app's rules, not just this one's"
        BAD=$((BAD + 1)); continue
      fi

      if [ -n "${STACK:-}" ]; then
        # Require this app's OWN stack tier, literal or via the variable.
        if ! printf '%s' "$st" | grep -qE "global-(${STACK}|\\\$\{?HARNESS_STACK)"; then
          wrong=$(printf '%s' "$st" | grep -oE "global-[a-z]+" | head -1)
          if [ -n "$wrong" ]; then
            fail "${f} — names ${wrong} but this app's stack is ${STACK}"
          else
            fail "${f} — predicate omits the stack tier (expected global-${STACK})"
          fi
          note "$short"
          BAD=$((BAD + 1)); continue
        fi
      elif ! printf '%s' "$st" | grep -q 'global-'; then
        fail "${f} — predicate omits the stack tier"
        note "$short"
        BAD=$((BAD + 1)); continue
      fi

      # And the app's own tier: selecting global + stack but not <app> silently
      # drops every app-specific rule.
      if [ -n "${APPNAME:-}" ] \
         && ! printf '%s' "$st" | grep -qE "'${APPNAME}'|\\\$\{?HARNESS_APP"; then
        fail "${f} — predicate omits this app's own tier ('${APPNAME}')"
        note "$short"
        BAD=$((BAD + 1))
      fi
    done <<< "$statements"
  done <<< "$READER_FILES"

  if [ "$BAD" -eq 0 ]; then
    if [ "$SEEN" -eq 0 ]; then
      note "no queries against agent_harness.rules found"
    else
      pass "all ${SEEN} agent_harness.rules queries select global + global-${STACK:-<stack>} + ${APPNAME:-<app>}"
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
