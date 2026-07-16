#!/usr/bin/env bash
# Registers an *ephemeral* self-hosted GitHub Actions runner against a repo, runs
# one job, then exits — Compose's restart policy brings it back and it re-registers.
#
# Generic and app-agnostic: REPO_OWNER / REPO_NAME / RUNNER_NAME / RUNNER_LABELS /
# GITHUB_PAT all come from the environment (set by bin/ci-runner from apps/<app>.env).
# Baked into the base image; shared by every harness app's runner. See ci-runner/README.md.
set -euo pipefail

: "${GITHUB_PAT:?GITHUB_PAT is required}"
: "${REPO_OWNER:?REPO_OWNER is required}"
: "${REPO_NAME:?REPO_NAME is required}"
: "${RUNNER_NAME:?RUNNER_NAME is required}"
: "${RUNNER_LABELS:?RUNNER_LABELS is required}"
API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"

# Mint a runner registration/removal token via the GitHub API.
# Echoes the token on success; on failure names the ACTUAL cause and returns non-zero.
# Deliberately not `curl -f` so set -o pipefail can't kill the script before the diagnostic.
#
# The diagnosis has to follow the status code. This used to print "the PAT needs
# Administration: Read and write, and must not be expired" for *every* failure — so on
# 2026-07-14 it said exactly that, 49 cycles running, while the PAT was fine and the real
# fault was the host having exhausted its ephemeral ports (VEN-1316). An operator following
# that advice rotates a working token and is no closer. A wrong cause costs more than no
# cause, because it forecloses the right one.
mint_runner_token() {
  local endpoint="$1" resp rc code body curl_msg
  resp="$(curl -sSL -w $'\n%{http_code}' -X POST \
    -H "Authorization: Bearer ${GITHUB_PAT}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API}/actions/runners/${endpoint}" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    # curl itself failed, so no response was received and the credentials were never judged.
    # Whatever this is, it is not the PAT. `resp` holds curl's own stderr (that is what -sS
    # is for) followed by the -w line; strip the latter and print curl's actual message
    # rather than guessing at a cause.
    curl_msg="${resp%$'\n'*}"        # drop the -w line; curl still emits it on failure
    curl_msg="${curl_msg%"${curl_msg##*[![:space:]]}"}"   # and its trailing blank line
    echo "❌ POST /actions/runners/${endpoint} — could not reach GitHub (curl exit ${rc})." >&2
    echo "   ${curl_msg}" >&2
    echo "   No response was received, so this is NOT the PAT — do not rotate it. Check egress:" >&2
    echo "     docker exec <app>-runner-N-runner-1 curl -sS -o /dev/null -w '%{http_code}' https://api.github.com" >&2
    echo "   (this container shares dind's netns, so \$HOSTNAME here is dind's id, not its own)" >&2
    echo "   'Can't assign requested address' means the *host* is out of ephemeral ports;" >&2
    echo "   check 'netstat -an -f inet | grep -c TIME_WAIT' on the Mac (see VEN-1316)." >&2
    return 1
  fi
  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  case "$code" in
    201) jq -r '.token // empty' <<<"$body"; return 0 ;;
    401) echo "❌ POST /actions/runners/${endpoint} → 401. The PAT is invalid or expired." >&2 ;;
    403) echo "❌ POST /actions/runners/${endpoint} → 403. The PAT lacks repo 'Administration: Read and write' on ${REPO_OWNER}/${REPO_NAME}, or is rate-limited." >&2
         echo "   ${body}" >&2 ;;
    404) echo "❌ POST /actions/runners/${endpoint} → 404. ${REPO_OWNER}/${REPO_NAME} not found, or the PAT can't see it (check REPO_OWNER/REPO_NAME in apps/*.env)." >&2 ;;
    5??) echo "❌ POST /actions/runners/${endpoint} → ${code}. GitHub-side error; this should clear on its own." >&2
         echo "   ${body}" >&2 ;;
    *)   echo "❌ POST /actions/runners/${endpoint} → ${code:-000}." >&2
         echo "   ${body}" >&2 ;;
  esac
  return 1
}

echo "⏳ Waiting for the Docker-in-Docker daemon (${DOCKER_HOST:-unset})…"
for i in $(seq 1 30); do
  if docker info >/dev/null 2>&1; then echo "✅ dind ready."; break; fi
  if [ "$i" -eq 30 ]; then echo "❌ dind never became ready" >&2; exit 1; fi
  sleep 2
done

# Cycle-start cleanup. `--ephemeral` governs only the GitHub registration: Compose
# restarts this same container rather than recreating it, so neither dind nor this
# filesystem resets on its own. Both sides are cleaned here, every cycle.
#
# Best-effort by design — a cleanup failure must not abort the cycle and strand the pair
# — but reported rather than swallowed: a silent failure here is precisely how the disk
# filled last time.
scrub() { "$@" || echo "⚠️  cycle cleanup: '$*' failed; continuing (state may accumulate)." >&2; }

# 1. The paired dind daemon. dind is per-pair scratch (one Compose project per pair, each
#    with its own dind-storage), so everything inside it is disposable between jobs.
#    `rm -fv` catches what `system prune` cannot: prune only removes *stopped* containers,
#    so a job interrupted mid-run (e.g. the runner replaced by `up N` while it was busy)
#    leaves its `services:` containers *running*, squatting the pair's published ports —
#    every later job on this pair then dies at "Initialize containers" with
#    "Bind for 0.0.0.0:5432 failed: port is already allocated", and a re-run never clears it.
leftovers="$(docker ps -aq 2>/dev/null || true)"
if [ -n "$leftovers" ]; then
  echo "🧹 Removing $(printf '%s\n' "$leftovers" | wc -l | tr -d ' ') leftover container(s) from the previous cycle…"
  # shellcheck disable=SC2086  # deliberate word-splitting: one id per argument
  scrub docker rm -fv $leftovers
fi
scrub docker system prune -f >/dev/null
# `-a` (all unused), not anonymous-only: Actions `services:` and `supabase start` create
# *named* volumes, which anonymous-only pruning leaves behind forever. A surviving
# supabase_db_* volume is worse than a full disk — `supabase start` restores its stale
# PGDATA and `db:migrate` applies only the delta, so the parity gate passes against
# week-old schema the PR never produced. Safe: this pair's dind-storage and bundle-cache
# are volumes of the *host* daemon and are not visible from inside dind.
scrub docker volume prune -af >/dev/null

# 2. This container's own filesystem. Unaffected by DOCKER_HOST, and never reset by the
#    restart, so job leftovers accumulate for the container's whole life. `_work/` is
#    deliberately untouched: it holds the warm checkout and the tool cache.
scrub rm -rf /tmp/ferrum_user_data_dir_* /tmp/.org.chromium.*
if [ -d /home/runner/_diag ]; then
  scrub find /home/runner/_diag -type f -mtime +1 -delete
fi

echo "🔑 Minting a runner registration token for ${REPO_OWNER}/${REPO_NAME}…"
if ! REG_TOKEN="$(mint_runner_token registration-token)" || [ -z "$REG_TOKEN" ]; then
  echo "⏳ Backing off 60s before exit so the restart loop stays slow and legible." >&2
  sleep 60
  exit 1
fi

# Best-effort deregister on exit so a stopped runner doesn't linger as offline. Best-effort
# means "don't fail the cycle over it", not "say nothing": a deregistration that silently
# never happens is what leaves the stale same-name sessions `reset` exists to clear, and the
# `2>/dev/null || true` here hid both the reason and the fact.
cleanup() {
  echo "🧹 Deregistering runner…"
  local rm_token
  if ! rm_token="$(mint_runner_token remove-token)" || [ -z "$rm_token" ]; then
    echo "⚠️  Could not mint a remove-token; leaving '${RUNNER_NAME}' registered." >&2
    echo "   It will linger as offline until --replace reclaims the name on the next cycle." >&2
    return 0
  fi
  if ! ./config.sh remove --token "$rm_token" >/dev/null 2>&1; then
    echo "⚠️  config.sh remove failed; '${RUNNER_NAME}' may linger as offline." >&2
  fi
}
trap cleanup EXIT

echo "📝 Configuring ephemeral runner '${RUNNER_NAME}' [${RUNNER_LABELS}]…"
if ! ./config.sh --unattended \
  --url "$REPO_URL" \
  --token "$REG_TOKEN" \
  --name "$RUNNER_NAME" \
  --labels "$RUNNER_LABELS" \
  --ephemeral \
  --replace \
  --work _work \
  --disableupdate; then
  echo "❌ Runner configuration failed; backing off 30s before exit." >&2
  sleep 30
  exit 1
fi

echo "🏃 Runner online — waiting for a job (ephemeral: one job, then re-register)…"
# Not exec'd, so the EXIT trap runs after run.sh returns post-job.
./run.sh
