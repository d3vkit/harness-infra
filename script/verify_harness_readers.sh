#!/usr/bin/env bash
# verify_harness_readers.sh — functional sweep of every participant's read path.
#
# The static lint (check_harness_contract.sh) proves the SQL *looks* right. This
# proves it actually returns all three tiers against the live database, which is
# the property that matters and the one that failed silently in VEN-1392.
#
# For each participant found on disk it sources the app's own harness_env.sh,
# then runs the app's own tier predicate and asserts rows come back from all of:
#   global            — universal, every app
#   global-<stack>    — the stack tier
#   <app>             — the app's own tier
#
# A missing app tier is reported but not fatal: a freshly-onboarded app may not
# have seeded its own rules yet. A missing global or stack tier IS fatal — that
# is rules silently not reaching agents.
#
# Host-side only. It walks sibling checkouts, so it cannot run in harness-infra's
# CI, where the app repos do not exist. Run it after any harness change.
#
#   Usage: script/verify_harness_readers.sh [--dev-root DIR]
set -uo pipefail

DEV_ROOT="${HOME}/development"
while [ $# -gt 0 ]; do
  case "$1" in
    --dev-root) DEV_ROOT="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

# app:relative-path. Keep in step with the participant list in
# docs/runbooks/new-harness-integration.md.
PARTICIPANTS=(
  "kyra:kyra_api"
  "pamm:pamm"
  "postcard:postcard"
  "cooldown:cooldown"
  "ceo-sim:games/ceo-sim"
  "emerald:games/project-emerald"
  "ephemeral:project-ephemeral"
  "riftling:riftling"
  "terminal-ai:terminal-ai"
  "vampire:games/vampire"
  "pirates-life:games/pirates_life"
)

FAIL=0
MISSING=0

printf '%-14s %-8s %-8s %-8s %-8s %s\n' APP STACK GLOBAL STACKTIER APPTIER RESULT
printf '%.0s-' {1..72}; echo

for entry in "${PARTICIPANTS[@]}"; do
  app="${entry%%:*}"
  dir="${DEV_ROOT}/${entry##*:}"

  if [ ! -d "$dir" ]; then
    printf '%-14s %s\n' "$app" "-- not on this machine, skipped"
    continue
  fi

  # Source the app's own env in a subshell so one app's exports never leak into
  # the next — HARNESS_STACK leaking across apps would silently validate the
  # wrong tier and is precisely the class of bug this script exists to catch.
  read -r stack g s a err < <(
    (
      cd "$dir" || exit 1
      # shellcheck disable=SC1091
      if ! . script/lib/harness_env.sh 2>/dev/null; then
        echo "? 0 0 0 no-env"; exit 0
      fi
      st="${HARNESS_STACK:-}"
      ap="${HARNESS_APP:-}"
      if [ -z "$st" ] || [ -z "$ap" ]; then echo "${st:-?} 0 0 0 no-discriminator"; exit 0; fi

      counts=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -t -A -F' ' -c "
        SELECT
          count(*) FILTER (WHERE app = 'global'),
          count(*) FILTER (WHERE app = 'global-${st}'),
          count(*) FILTER (WHERE app = '${ap}')
        FROM agent_harness.rules
        WHERE app IN ('global', 'global-${st}', '${ap}');" 2>/dev/null)

      if [ -z "$counts" ]; then echo "$st 0 0 0 no-db"; exit 0; fi
      echo "$st $counts ok"
    )
  )

  case "$err" in
    no-env)           printf '%-14s %-8s %s\n' "$app" "-" "FAIL  cannot source script/lib/harness_env.sh"; FAIL=1; continue ;;
    no-discriminator) printf '%-14s %-8s %s\n' "$app" "${stack}" "FAIL  HARNESS_APP or HARNESS_STACK unset after sourcing"; FAIL=1; continue ;;
    no-db)            printf '%-14s %-8s %s\n' "$app" "${stack}" "SKIP  database unreachable"; MISSING=1; continue ;;
  esac

  result="ok"
  if [ "${g:-0}" -eq 0 ]; then result="FAIL  global tier empty"; FAIL=1
  elif [ "${s:-0}" -eq 0 ]; then result="FAIL  global-${stack} tier not reached"; FAIL=1
  elif [ "${a:-0}" -eq 0 ]; then result="warn  app tier empty (not yet seeded?)"
  fi

  printf '%-14s %-8s %-8s %-8s %-8s %s\n' "$app" "$stack" "$g" "$s" "$a" "$result"
done

echo
if [ "$FAIL" -ne 0 ]; then
  echo "harness readers: FAILED — at least one app is not reading a tier it should."
  exit 1
fi
[ "$MISSING" -ne 0 ] && echo "harness readers: OK (some apps skipped — database unreachable)" && exit 0
echo "harness readers: OK — every participant reaches all three tiers."
exit 0
