#!/usr/bin/env bash
# Reclaim Docker disk on the shared workspace VM. DENY BY DEFAULT, dry run unless --apply.
#
# ── WHY THIS IS NOT `docker volume prune` ────────────────────────────────────────────
# Measured on this box: all 22 currently-dangling volumes are databases (postgres, redis,
# supabase, elasticsearch), including anonymous 64-hex volumes that are the live PGDATA of
# `pamm-test-pg` and `pc-schema-test` and match no name pattern at all. "Dangling" means
# "referenced by no container right now" — a reachability fact, not a liveness signal, and
# true of every stopped app stack. A host-level `docker volume prune -af` would delete all
# 22. This script therefore never reasons from a denylist of things to spare.
#
# ── WHY THE DEVCONTAINER DIND VOLUMES ARE NOT TOUCHED ───────────────────────────────
# `<app>_dind-var-lib-docker-<hash>` is the biggest leaker and is EXCLUDED here, reported
# only. Two measured reasons: (a) while its devcontainer exists the volume is referenced,
# so it is never `dangling=true` and is not reclaimable anyway — and `docker stop` does not
# change that, only `docker rm` would; (b) when it IS unreferenced it still contains that
# app's NESTED volumes, i.e. `supabase_db_pamm`, `supabase_storage_postcard`. Deleting it
# destroys another app's local database and uploaded objects, which no migration recreates.
# The real fix is to stop minting one per worktree path (pin a stable volume name in
# devcontainer.json) — that is a per-app change, not this script's job.
#
# The runner entrypoint's `docker volume prune -af` is correct where it is: it runs with
# DOCKER_HOST pointed at the pair's own dind, whose contents are per-job scratch. It cannot
# see host volumes at all, which is why the 46 GB host-level leak survived it.
set -uo pipefail   # deliberately NOT -e: this must run to completion and report.

VERSION=2
STATE_DIR="${HARNESS_REAP_STATE_DIR:-$HOME/.local/state/harness-reap}"
LOG_FILE="${HARNESS_REAP_LOG:-$HOME/Library/Logs/harness/reap-docker-disk.log}"
LEDGER="$STATE_DIR/quarantine.tsv"
LAST_RUN="$STATE_DIR/last-run.json"
LOCK_DIR="$STATE_DIR/.lock"

GRACE_HOURS="${HARNESS_REAP_GRACE_HOURS:-48}"   # continuously orphaned before removal
KEEP_HOURS="${HARNESS_REAP_KEEP_HOURS:-168}"    # image / build-cache `until` filter
FREE_WARN_PCT="${HARNESS_REAP_FREE_WARN_PCT:-15}"

APPLY=0; PRUNE_NESTED=0; RC=0

usage() {
  cat <<'USAGE'
Usage: script/reap-docker-disk.sh [--apply] [--prune-nested]

  (default)        Dry run. Reports only; removes nothing.
  --apply          Actually remove Tier-0 and matured Tier-1 items.
  --prune-nested   Also prune inside each devcontainer's nested daemon: build cache and
                   DANGLING images only. Never --volumes (nested supabase PGDATA lives
                   there), never -a (evicting tagged images forces a ~10-image supabase
                   re-pull over the NAT that VEN-1107 exists because of), never containers
                   (a stopped supabase_edge_runtime_* is a member of a RUNNING stack).
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --prune-nested) PRUNE_NESTED=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac; shift
done

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")" 2>/dev/null
exec > >(tee -a "$LOG_FILE") 2>&1

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
# Best-effort per action, but NAMED and it makes the run exit non-zero. No blanket
# `|| true` anywhere: a swallowed failure is how the disk filled last time. Note this
# returns 0 — it must not abort the run (the reviewed draft returned 1 and killed it).
try() { if ! "$@"; then log "⚠️  '$*' failed; continuing."; RC=1; fi; return 0; }

write_state() {
  printf '{"version":%d,"finished_at":"%s","exit_code":%d,"apply":%d,"status":"%s","removed":%d,"quarantined":%d,"free_pct":"%s"}\n' \
    "$VERSION" "$(date -u +%FT%TZ)" "$RC" "$APPLY" "$1" "${2:-0}" "${3:-0}" "${4:-unknown}" > "$LAST_RUN"
}

# Single instance. No flock(1) on macOS, so atomic mkdir — but a stale lock (SIGKILL,
# sleep mid-run, reboot) must not disable the reaper forever while printing a reassuring
# message. Age it out, and write state on EVERY exit path so the heartbeat can tell
# "skipped" from "healthy".
if mkdir "$LOCK_DIR" 2>/dev/null; then
  trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT
else
  lock_age=$(( ( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0) ) / 3600 ))
  if [ "$lock_age" -ge 6 ]; then
    log "ℹ️  stale lock (${lock_age}h old) — taking it over."
    trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT
  else
    log "ℹ️  another reap is in progress; exiting."
    write_state "skipped-locked"; exit 0
  fi
fi

if ! docker info >/dev/null 2>&1; then
  # Not healthy — a Docker Desktop that has been off for a month must not read green.
  log "⚠️  Docker is not running; nothing was reclaimed."
  RC=1; write_state "skipped-docker-down"; exit 1
fi

log "════════ harness docker-disk reap v${VERSION} (apply=${APPLY}) ════════"
docker system df 2>/dev/null | sed 's/^/    /'

# ── Tier 0: zero-data-risk ───────────────────────────────────────────────────────────
# `image prune` WITHOUT -a is dangling-only, so the tagged harness-runner:* images and the
# SKIP_IMAGE_BUILD=1 recovery path are untouched. `buildx prune` with until=168h leaves a
# week of cache, so a routine `bin/ci-runner <app> up` still hits warm layers.
if [ "$APPLY" = 1 ]; then
  log "── Tier 0: dangling images + build cache older than ${KEEP_HOURS}h"
  try docker image  prune -f --filter "until=${KEEP_HOURS}h"
  try docker buildx prune -f --filter "until=${KEEP_HOURS}h"
else
  log "── Tier 0 (dry run): would prune dangling images + build cache older than ${KEEP_HOURS}h"
fi

# ── Tier 1: orphaned runner-pair volumes ─────────────────────────────────────────────
# Keyed on the owning Compose PROJECT having no containers at all — not on a name regex
# (which misses `kyra-ci-runner_dind-storage` and `harness-ci-runner_dind-storage`, both
# real 4-6 GB leakers) and not on `dangling=true` alone. This is the `kyra-runner-2_*`
# case that scaling back from two pairs creates. Worst case of a wrong delete is a warm
# cache re-warming, because both mount targets are caches by construction.
live_projects="$(docker ps -a --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null | sort -u)"
now=$(date +%s); grace=$(( GRACE_HOURS * 3600 ))
candidates=(); quarantined=(); removed=0

[ -f "$LEDGER" ] || : > "$LEDGER"
: > "$LEDGER.new"

while IFS= read -r v; do
  [ -n "$v" ] || continue
  proj="${v%_dind-storage}"; proj="${proj%_bundle-cache}"
  printf '%s\n' "$live_projects" | grep -qxF -- "$proj" && continue
  # Independent re-check, cheap by now: `docker volume rm` also refuses an in-use volume,
  # so reference-safety holds even if the list above were computed wrong.
  [ -n "$(docker ps -a --filter "volume=$v" -q 2>/dev/null)" ] && continue
  candidates+=("$v")
done < <(docker volume ls -q 2>/dev/null | grep -E '_(dind-storage|bundle-cache)$' || true)

for v in ${candidates[@]+"${candidates[@]}"}; do
  # Real tabs, and the volume name (never multi-line) is the only thing passed via -v.
  first="$(awk -F'\t' -v n="$v" '$1==n{print $2; exit}' "$LEDGER" 2>/dev/null)"
  [ -n "$first" ] || first="$now"
  printf '%s\t%s\n' "$v" "$first" >> "$LEDGER.new"
  if [ $(( now - first )) -lt "$grace" ]; then
    quarantined+=("$v")
    log "    ⏳ $v — orphaned, eligible in ~$(( (grace - (now - first)) / 3600 + 1 ))h"
  elif [ "$APPLY" = 1 ]; then
    if docker volume rm "$v" >/dev/null 2>&1; then
      log "    🗑  removed $v"; removed=$(( removed + 1 ))
    else
      log "    ⚠️  could not remove $v (in use?)"; RC=1
    fi
  else
    log "    would remove $v (matured)"
  fi
done
# Rewriting from the current candidate set means a volume that came back into use drops
# out and its clock restarts: the grace period measures CONTINUOUS orphanhood.
mv "$LEDGER.new" "$LEDGER" 2>/dev/null

log "── Tier 1: ${removed} removed, ${#quarantined[@]} in quarantine"

# ── Reported, never touched ──────────────────────────────────────────────────────────
# A cleanup tool that only speaks when it acts trains everyone to ignore it. If either
# list grows without bound, a human decides; this script will not.
log "── Reported only (never removed by this script):"
docker volume ls -q 2>/dev/null | grep -E '_dind-var-lib-docker-' \
  | sed 's/^/    · devcontainer nested graph (holds that app'"'"'s supabase DBs): /' || true
docker volume ls -qf dangling=true 2>/dev/null \
  | sed 's/^/    · unreferenced, not reapable: /' || true

# ── Tier 2 (opt-in): inside the devcontainers' nested daemons ────────────────────────
if [ "$PRUNE_NESTED" = 1 ]; then
  for c in $(docker ps --format '{{.Names}}' 2>/dev/null | grep -E -- '-rails-app-1$' || true); do
    docker exec "$c" docker info >/dev/null 2>&1 || continue
    log "── Tier 2: $c (build cache + dangling images only)"
    docker exec "$c" docker system df 2>/dev/null | sed 's/^/    before: /'
    if [ "$APPLY" = 1 ]; then
      try docker exec "$c" docker image  prune -f --filter "until=${KEEP_HOURS}h"
      try docker exec "$c" docker buildx prune -f --filter "until=${KEEP_HOURS}h"
      docker exec "$c" docker system df 2>/dev/null | sed 's/^/    after:  /'
    fi
  done
fi

# ── Headroom ─────────────────────────────────────────────────────────────────────────
# Read from INSIDE a container: that is the Linux VM's graph filesystem, the disk that
# actually fills. A host bind mount (`-v /:/host`) reads the Mac's APFS instead — measured
# 47% free in the VM vs 95% free on the Mac at the same moment.
probe="$(docker ps -q 2>/dev/null | head -1)"
free_pct=""
[ -n "$probe" ] && free_pct="$(docker exec "$probe" df -P / 2>/dev/null | awk 'NR==2{print 100-$5+0}')"

if [ -z "$free_pct" ]; then
  log "⚠️  Could not read Docker VM disk headroom — treat as unknown, NOT healthy."; RC=1
elif [ "$free_pct" -lt "$FREE_WARN_PCT" ]; then
  log "🔴 Docker VM ${free_pct}% free (<${FREE_WARN_PCT}%) — CI will start failing with PG::DiskFull."
  RC=1
  osascript -e "display notification \"Docker VM ${free_pct}% free\" with title \"harness disk reaper\"" >/dev/null 2>&1 || true
else
  log "    Docker VM ${free_pct}% free."
fi

docker system df 2>/dev/null | sed 's/^/    /'
write_state "ok" "$removed" "${#quarantined[@]}" "${free_pct:-unknown}"
log "════════ done (exit ${RC}) ════════"
exit "$RC"
