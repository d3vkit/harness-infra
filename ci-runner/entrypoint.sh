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

# ── Liveness watchdog ────────────────────────────────────────────────────────
# An ephemeral runner is only long-lived while *idle* — a job makes run.sh exit,
# and the restart re-registers. Two failure modes strand it idle-but-unreachable,
# and neither ends the cycle on its own, so `restart: always` never fires:
#
#   • Silent-dead — the server-side registration is dropped while Runner.Listener
#     keeps long-polling without error. Observed 2026-07-21 on kyra: "Listening for
#     Jobs" 22:31Z, first error only 23:22Z, recovered 23:33Z — ~1h offline. Under
#     Docker-VM RAM starvation (16 GB shared across 3 Rails apps + 4 runner/dind
#     pairs — see README → Sizing and apps/kyra.env) the starved listener misses its
#     GitHub heartbeat, GitHub drops the session, and the starved process is too slow
#     to even notice. No error is logged, so there is nothing to grep for.
#   • Retry-loop — once it does notice ("Retrying until reconnected." / "listener
#     exit with retryable error, re-launch runner in 5 seconds.") run.sh relaunches
#     the listener in place against a dead session. Observed 2026-07-19 on ephemeral:
#     23:33Z → 02:09Z, ~2.5h looping before it cleared on its own.
#
# The watchdog bounds both to minutes by forcing a *clean* re-register: end run.sh so
# the EXIT trap deregisters and restart:always mints a fresh registration token and
# re-configs. A fresh registration succeeds where an in-place relaunch against a
# dropped session cannot; when the real fault is egress, the restart routes through
# entrypoint's mint-token diagnostic instead of run.sh's opaque 5s relaunch. This
# bounds the *symptom* — the root cause is VM RAM (README → Sizing); more RAM / fewer
# always-on apps is what removes it.
: "${RUNNER_IDLE_MAX_SECONDS:=900}"  # re-register after this long idle with no job (0 disables the backstop)
: "${RUNNER_WATCH_INTERVAL:=30}"     # how often the watchdog looks
RUN_LOG="/home/runner/_run.log"      # run.sh's own output (agent lifecycle only; job step logs don't land here)

# The latest significant listener state, read from run.sh's output. run.sh emits only
# a handful of lifecycle lines per cycle, so scanning the whole (truncated-per-cycle)
# log is cheap. `|| true` keeps a no-match grep from tripping `set -e`.
runner_state() {
  local last=""
  [ -f "$RUN_LOG" ] && last="$(grep -aE 'Listening for Jobs|Running job:|completed with result:|Retrying until reconnected|listener exit with retryable error|Registration .* was not found' "$RUN_LOG" 2>/dev/null | tail -n1 || true)"
  case "$last" in
    *"Running job:"*) echo busy ;;
    *"Retrying until reconnected"*|*"listener exit with retryable error"*|*"was not found"*) echo disconnected ;;
    *) echo idle ;;  # "Listening for Jobs", a just-completed job, or nothing logged yet
  esac
}

# True while a job is actually executing — the watchdog must never end the cycle then.
# Prefer the live worker process; fall back to the log so a pgrep miss still holds.
job_running() {
  pgrep -f 'Runner\.Worker' >/dev/null 2>&1 && return 0
  [ "$(runner_state)" = busy ]
}

# Watch the (backgrounded) run.sh session leader; when it is idle-but-unreachable, end
# its whole process group so entrypoint falls through to the EXIT trap and restarts.
liveness_watchdog() {
  local leader="$1" idle_since strikes=0
  idle_since="$(date +%s)"
  while kill -0 "$leader" 2>/dev/null; do
    sleep "$RUNNER_WATCH_INTERVAL"
    kill -0 "$leader" 2>/dev/null || return 0   # run.sh exited on its own (normal one-job path)
    if job_running; then idle_since="$(date +%s)"; strikes=0; continue; fi
    case "$(runner_state)" in
      disconnected)
        # Fast path: a persistent disconnect while idle. Two strikes (~2 polls) so a
        # transient blip that self-heals between polls doesn't force a needless re-register.
        strikes=$((strikes + 1))
        if [ "$strikes" -ge 2 ]; then
          echo "🩺 watchdog: idle listener stuck on a dropped connection — forcing a clean re-register." >&2
          break
        fi
        ;;
      *)
        strikes=0
        # Backstop: idle far longer than any healthy session should live without a job.
        # This is the only thing that catches silent-dead, where no error is ever logged.
        if [ "${RUNNER_IDLE_MAX_SECONDS:-0}" -gt 0 ] && [ "$(( $(date +%s) - idle_since ))" -ge "$RUNNER_IDLE_MAX_SECONDS" ]; then
          echo "🩺 watchdog: idle ${RUNNER_IDLE_MAX_SECONDS}s with no job — forcing a fresh re-register (bounds the silent-dead state)." >&2
          break
        fi
        ;;
    esac
  done
  # Guard the sub-second "job assigned but Worker not yet spawned" race before ending.
  if job_running; then
    echo "🩺 watchdog: a job started as the timer fired — standing down, not ending the cycle." >&2
    return 0
  fi
  # End run.sh AND the Runner.Listener it supervises in one group signal — run.sh
  # relaunches a bare-killed listener (returnCode 2), so a half-kill would just respawn
  # it. TERM, brief grace, then KILL. entrypoint's `wait` returns → EXIT trap deregisters.
  kill -TERM -"$leader" 2>/dev/null || true
  for _ in 1 2 3 4 5; do kill -0 "$leader" 2>/dev/null || break; sleep 1; done
  kill -KILL -"$leader" 2>/dev/null || true
}

echo "🏃 Runner online — waiting for a job (ephemeral: one job, then re-register)…"
# run.sh in its own session so the watchdog can end its whole process group with one
# signal. Output is tee'd to $RUN_LOG (for the disconnect fast-path) and to stdout (so
# `ci-runner logs` is unchanged). Not exec'd — the EXIT trap must still run after run.sh
# returns, whether from a completed job or a watchdog-forced re-register.
: > "$RUN_LOG"
setsid bash -c './run.sh 2>&1' > >(tee -a "$RUN_LOG") &
RUNNER_LEADER=$!
# On container stop (`ci-runner down`, compose stop) end the group too — otherwise the
# setsid session outlives entrypoint and only dies on SIGKILL. The EXIT trap still runs.
trap 'kill -TERM -"$RUNNER_LEADER" 2>/dev/null || true' TERM INT
liveness_watchdog "$RUNNER_LEADER" &
WATCHDOG_PID=$!
wait "$RUNNER_LEADER" || true
kill "$WATCHDOG_PID" 2>/dev/null || true
wait "$WATCHDOG_PID" 2>/dev/null || true
