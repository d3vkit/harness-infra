#!/usr/bin/env bash
# Registers a self-hosted GitHub Actions runner against a repo.
#
# Registration mode is PER-APP via RUNNER_EPHEMERAL (apps/<app>.env), default 1:
#   1 (default) — `--ephemeral`: one job, then exit; Compose's restart policy brings it
#                 back and it re-registers. Byte-identical to what every app does today,
#                 so an app that has not opted out is unaffected by this file's changes.
#   0           — long-lived: many jobs per container. Per-job cleanliness then comes
#                 from hooks/job-started.sh (ACTIONS_RUNNER_HOOK_JOB_STARTED), NOT from
#                 the restart. Opt in ONE app at a time; see ci-runner/README.md.
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

# Cycle-start cleanup, now shared with hooks/job-started.sh so the boot path and the
# per-job path cannot drift. Under RUNNER_EPHEMERAL=1 this is still the only scrub and
# still runs every cycle, exactly as before. Under RUNNER_EPHEMERAL=0 it clears whatever
# the previous container life left behind, and the job-started hook takes the per-job
# cadence the container restart used to provide.
# shellcheck source=lib/scrub.sh
. /home/runner/lib/scrub.sh
harness_scrub boot

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
#
# Under RUNNER_EPHEMERAL=0 this is the ONLY thing that removes the registration —
# `--ephemeral` made GitHub delete it server-side after each job, so this trap was the
# braces to that belt. Without the flag, the belt is gone. It also matters more than it
# looks: a registered-but-offline runner whose labels match makes GitHub QUEUE a job for
# up to 24h with no error, rather than failing fast with "no runner matching the labels".
cleanup() {
  echo "🧹 Deregistering runner…"
  local rm_token
  if ! rm_token="$(mint_runner_token remove-token)" || [ -z "$rm_token" ]; then
    echo "⚠️  Could not mint a remove-token; leaving '${RUNNER_NAME}' registered." >&2
    echo "   It will linger as offline. The next start clears the LOCAL config and" >&2
    echo "   --replace reclaims the server-side name, so this is recoverable." >&2
    return 0
  fi
  if ! ./config.sh remove --token "$rm_token" >/dev/null 2>&1; then
    echo "⚠️  config.sh remove failed; '${RUNNER_NAME}' may linger as offline." >&2
  fi
}

# ── Registration mode ────────────────────────────────────────────────────────────────
# Validated, not treated as a truthy test: a typo (RUNNER_EPHEMRAL=0) that silently
# selects the other mode is the failure you cannot see. Back off before exiting so the
# restart loop stays slow and legible, matching every other failure path in this file.
case "${RUNNER_EPHEMERAL:-1}" in
  1|true|yes)
    EPHEMERAL_ARGS=(--ephemeral)
    MODE_DESC="ephemeral (one job, then re-register)"
    ;;
  0|false|no)
    EPHEMERAL_ARGS=()
    MODE_DESC="long-lived (many jobs; per-job scrub via the job-started hook)"
    # actions/runner 2.335.1's run.sh branches on this: unset, it calls run(), which
    # installs NO trap and holds run-helper.sh (→ Runner.Listener) in the FOREGROUND, so
    # a TERM to run.sh's wrapper never reaches the listener. Set, it calls
    # runWithManualTrap(), which does `set -m` + `trap 'kill -INT -$PID' INT TERM`,
    # signalling the process GROUP. Without this, the backgrounding below is inert.
    export RUNNER_MANUALLY_TRAP_SIG=1
    if [ -x /home/runner/hooks/job-started.sh ]; then
      export ACTIONS_RUNNER_HOOK_JOB_STARTED=/home/runner/hooks/job-started.sh
      echo "🪝 Per-job scrub enabled (mode=${CI_RUNNER_SCRUB_MODE:-full})."
    else
      # FAIL OPEN. A missing hook file makes GitHub fail every job this runner picks up.
      # A pair that only scrubs at boot is degraded; a pair that cannot run any job is down.
      echo "⚠️  /home/runner/hooks/job-started.sh missing — per-job scrub DISABLED." >&2
      echo "   The image predates this feature (SKIP_IMAGE_BUILD=1?). Jobs still run, but" >&2
      echo "   expect 'port is already allocated' and stale supabase_db_* volumes." >&2
      echo "   Rebuild: bin/ci-runner <app> up" >&2
    fi
    ;;
  *)
    echo "❌ RUNNER_EPHEMERAL must be 0 or 1 (got '${RUNNER_EPHEMERAL}'); backing off 30s." >&2
    sleep 30
    exit 2
    ;;
esac

# ── Clear stale LOCAL config before configuring ──────────────────────────────────────
# Runner.Listener hard-refuses to configure over an existing local config: "Cannot
# configure the runner because it is already configured." `--replace` does NOT bypass it
# — that flag resolves the SERVER-side name collision only.
#
# Today this is masked because `--ephemeral` makes the runner delete .runner/.credentials
# after each job. It is still a latent bug even in ephemeral mode (a SIGKILL mid-job
# strands them: .runner IS present on an idle runner right now), and under
# RUNNER_EPHEMERAL=0 it becomes the normal case — every OOM-kill, Docker Desktop restart
# or host reboot would otherwise crash-loop the pair forever at the `sleep 30; exit 1`
# below, firing two GitHub API calls per iteration against a PAT shared by four repos.
# Applies to BOTH modes: it is a strict fix.
if [ -f .runner ]; then
  echo "♻️  Stale local runner config from a previous container life — clearing."
  if rm_tok="$(mint_runner_token remove-token)" && [ -n "$rm_tok" ]; then
    ./config.sh remove --token "$rm_tok" >/dev/null 2>&1 || true
  fi
  rm -f .runner .credentials .credentials_rsaparams .path
fi

echo "📝 Configuring runner '${RUNNER_NAME}' [${RUNNER_LABELS}] — ${MODE_DESC}…"
if ! ./config.sh --unattended \
  --url "$REPO_URL" \
  --token "$REG_TOKEN" \
  --name "$RUNNER_NAME" \
  --labels "$RUNNER_LABELS" \
  ${EPHEMERAL_ARGS[@]+"${EPHEMERAL_ARGS[@]}"} \
  --replace \
  --work _work \
  --disableupdate; then
  echo "❌ Runner configuration failed; backing off 30s before exit." >&2
  sleep 30
  exit 1
fi

# Armed only AFTER a successful configure. Previously this trap was installed before
# config.sh, so a config failure spun two GitHub API calls every 30s forever on the
# shared PAT.
trap cleanup EXIT

if [ "${#EPHEMERAL_ARGS[@]}" -gt 0 ]; then
  # ── Ephemeral: unchanged from today, deliberately byte-identical. ─────────────────
  echo "🏃 Runner online — waiting for a job (ephemeral: one job, then re-register)…"
  # Not exec'd, so the EXIT trap runs after run.sh returns post-job.
  ./run.sh
else
  # ── Long-lived: run.sh must go to the BACKGROUND. ────────────────────────────────
  # Two reasons, both new consequences of run.sh no longer returning after one job:
  #  1. ORDERING. bash runs its EXIT trap on SIGTERM while a FOREGROUND child is still
  #     alive. Left in the foreground, `docker stop` would fire cleanup() and run
  #     `config.sh remove` against a live listener session. Under --ephemeral this could
  #     not happen: the trap only ever ran once run.sh had already returned.
  #  2. SIGNALS. `docker stop` SIGTERMs PID 1 (tini, from `init: true`), which forwards
  #     to this shell and nothing else. run.sh is a grandchild.
  echo "🏃 Runner online — serving jobs until the container is stopped."
  shutdown_runner() {
    echo "🛑 SIGTERM/SIGINT — asking the runner to stop…"
    if [ -n "${RUN_PID:-}" ]; then kill -TERM "$RUN_PID" 2>/dev/null || true; fi
    return 0
  }
  trap shutdown_runner TERM INT

  ./run.sh &
  RUN_PID=$!

  # `wait` returns 128+n the moment a trapped signal arrives, with the child possibly
  # still alive, so waiting once is not enough. `|| RUN_RC=$?` rather than a bare `wait`
  # because `set -e` would otherwise abort on the 143 and skip the drain — reintroducing
  # the exact race this is fixing. No `kill -0` predicate on the loop: a fast-failing
  # run.sh reaped before the first check would otherwise swallow its exit code.
  RUN_RC=0
  while :; do
    RUN_RC=0
    wait "$RUN_PID" || RUN_RC=$?
    if [ "$RUN_RC" -le 128 ]; then break; fi
    if ! kill -0 "$RUN_PID" 2>/dev/null; then break; fi
  done

  if [ "$RUN_RC" -gt 128 ]; then
    echo "run.sh exited on signal $((RUN_RC - 128))."
  elif [ "$RUN_RC" -ne 0 ]; then
    echo "⚠️  run.sh exited ${RUN_RC}; deregistering, and Compose will restart the pair." >&2
  fi
  exit "$RUN_RC"
fi
