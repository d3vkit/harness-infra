#!/usr/bin/env bash
# Shared runner cleanup. Sourced by entrypoint.sh (phase "boot", at container start) and
# by hooks/job-started.sh (phase "job", before each job on a long-lived runner). One
# implementation, two call sites, so the boot path and the per-job path cannot drift —
# and drift would land in the destructive part.
#
# CONTRACT: harness_scrub MUST NEVER return non-zero and MUST NEVER exit.
# GitHub FAILS THE JOB when a job-started hook exits non-zero, and this image is shared by
# every harness app: a cleanup failure that reds everyone's CI is strictly worse than the
# state it failed to clean. Every failure is NAMED and swallowed. Do not add `set -e` here.

# Best-effort, BOUNDED, and reported — not silenced. entrypoint.sh's original comment still
# applies verbatim: "a silent failure here is precisely how the disk filled last time."
scrub() {
  local rc=0
  timeout -k 5s 60s "$@" || rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    echo "⚠️  scrub: '$*' timed out after 60s (dind may be wedged); continuing." >&2
  elif [ "$rc" -ne 0 ]; then
    echo "⚠️  scrub: '$*' failed (exit ${rc}); continuing (state may accumulate)." >&2
  fi
  return 0
}

# $1 = boot | job
harness_scrub() {
  local phase="${1:-boot}" mode="${CI_RUNNER_SCRUB_MODE:-full}" leftovers

  # DOCKER_HOST is set on the runner container by compose.yaml and inherited down to job
  # steps. Default it anyway: unset, the CLI falls back to /var/run/docker.sock, finds no
  # daemon, and this whole scrub degrades into a no-op that still logs like it worked.
  export DOCKER_HOST="${DOCKER_HOST:-tcp://localhost:2375}"

  # ONE cheap liveness probe, before anything else. Every pass below talks to the paired
  # dind daemon; a wedged daemon would otherwise block until each per-command timeout
  # fires, and on the job path those add up serially inside "Set up runner" — minutes of
  # added wall clock on every job of every app, on a VM whose capacity is the problem.
  # Fail once in 5s instead of five times in 60s.
  if ! timeout 5s docker version >/dev/null 2>&1; then
    echo "⚠️  scrub[${phase}]: dind unreachable at ${DOCKER_HOST}; skipping the dind passes." >&2

  elif [ "$phase" = "job" ] && [ "$mode" != "full" ]; then
    # ROLLOUT GATE, not a heuristic. The destructive sweep is correct only if this hook is
    # a PRE-job step. The evidence says it is — in Runner.Worker.dll the string table reads
    # "ACTIONS_RUNNER_HOOK_JOB_STARTED" immediately followed by "Initialize containers" —
    # but the cost of being wrong is deleting the job's own postgres/redis on every job of
    # every app. So the first job on a newly-opted-in app runs in report mode and an
    # operator reads the list below. Flip CI_RUNNER_SCRUB_MODE=full in apps/<app>.env once
    # confirmed. Also a permanent kill-switch: no image rebuild needed to disarm.
    echo "🔎 scrub[job]: CI_RUNNER_SCRUB_MODE=${mode} — REPORT ONLY, nothing will be removed."
    echo "   Containers visible to this hook right now. This list must NOT contain this"
    echo "   job's own services: — if it does, the hook is running AFTER 'Initialize"
    echo "   containers' and CI_RUNNER_SCRUB_MODE must stay at 'report'."
    timeout 15s docker ps -a --format '   · {{.ID}} {{.Image}} {{.Names}} [{{.Status}}]' 2>/dev/null || true

  else
    # `rm -fv` catches what `system prune` cannot: prune only removes *stopped* containers,
    # so a job interrupted mid-run leaves its `services:` containers RUNNING, squatting the
    # pair's published ports — every later job then dies at "Initialize containers" with
    # "Bind for 0.0.0.0:5432 failed: port is already allocated", and a re-run never clears
    # it. Under --ephemeral the container restart guaranteed this ran between jobs.
    leftovers="$(timeout 15s docker ps -aq 2>/dev/null || true)"
    if [ -n "$leftovers" ]; then
      echo "🧹 scrub[${phase}]: removing $(printf '%s\n' "$leftovers" | wc -l | tr -d ' ') leftover container(s)…"
      # shellcheck disable=SC2086  # deliberate word-splitting: one id per argument
      scrub docker rm -fv $leftovers
    fi
    scrub docker system prune -f >/dev/null
    # `-a` (all unused), not anonymous-only: `services:` and `supabase start` create NAMED
    # volumes. A surviving supabase_db_* volume is worse than a full disk — `supabase start`
    # restores its stale PGDATA and `db:migrate` applies only the delta, so the parity gate
    # PASSES against week-old schema the PR never produced. This is a CORRECTNESS control,
    # not disk hygiene, which is why it must not be dropped from the job path.
    scrub docker volume prune -af >/dev/null
  fi

  # This container's own filesystem. Unaffected by DOCKER_HOST, and on a long-lived runner
  # never reset, so leftovers accumulate for the container's whole life. `_work/` is
  # deliberately untouched: it holds the warm checkout and the tool cache.
  scrub rm -rf /tmp/ferrum_user_data_dir_* /tmp/.org.chromium.*
  # -mtime +1 is load-bearing: the listener holds Runner_*.log open for the container's
  # whole life, and the mtime filter leaves the active file alone.
  if [ -d /home/runner/_diag ]; then
    scrub find /home/runner/_diag -type f -mtime +1 -delete
  fi

  return 0
}
