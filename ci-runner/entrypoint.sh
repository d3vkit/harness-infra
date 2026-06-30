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
# Echoes the token on success; on failure prints the HTTP status + likely cause and
# returns non-zero. Deliberately not `curl -f` so set -o pipefail can't kill the
# script before the diagnostic.
mint_runner_token() {
  local endpoint="$1" resp code body
  resp="$(curl -sSL -w $'\n%{http_code}' -X POST \
    -H "Authorization: Bearer ${GITHUB_PAT}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API}/actions/runners/${endpoint}" 2>/dev/null)" || true
  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  if [ "$code" != "201" ]; then
    echo "❌ POST /actions/runners/${endpoint} → HTTP ${code:-000}." >&2
    echo "   The PAT needs repo 'Administration: Read and write' on ${REPO_OWNER}/${REPO_NAME}, and must not be expired." >&2
    return 1
  fi
  jq -r '.token // empty' <<<"$body"
}

echo "⏳ Waiting for the Docker-in-Docker daemon (${DOCKER_HOST:-unset})…"
for i in $(seq 1 30); do
  if docker info >/dev/null 2>&1; then echo "✅ dind ready."; break; fi
  if [ "$i" -eq 30 ]; then echo "❌ dind never became ready" >&2; exit 1; fi
  sleep 2
done

# dind state persists in its volume across jobs; keep it from accumulating.
docker system prune -f >/dev/null 2>&1 || true

echo "🔑 Minting a runner registration token for ${REPO_OWNER}/${REPO_NAME}…"
if ! REG_TOKEN="$(mint_runner_token registration-token)" || [ -z "$REG_TOKEN" ]; then
  echo "⏳ Backing off 60s before exit so the restart loop stays slow and legible." >&2
  sleep 60
  exit 1
fi

# Best-effort deregister on exit so a stopped runner doesn't linger as offline.
cleanup() {
  echo "🧹 Deregistering runner…"
  local rm_token
  rm_token="$(mint_runner_token remove-token 2>/dev/null || true)"
  if [ -n "${rm_token:-}" ]; then
    ./config.sh remove --token "$rm_token" >/dev/null 2>&1 || true
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
  --work _work; then
  echo "❌ Runner configuration failed; backing off 30s before exit." >&2
  sleep 30
  exit 1
fi

echo "🏃 Runner online — waiting for a job (ephemeral: one job, then re-register)…"
# Not exec'd, so the EXIT trap runs after run.sh returns post-job.
./run.sh
