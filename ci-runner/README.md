# Shared self-hosted CI runners

Run any harness app's GitHub Actions CI on your own machine at **$0 billed minutes**,
instead of GitHub-hosted runners. GitHub still orchestrates everything (PR checks,
branch protection, the Actions UI) — only the *compute* moves here.

This is the centrally-owned runner infra, mirroring how this repo owns the shared
Postgres and the global rule tiers: one **base image** + **per-stack toolchain
images**, driven by thin **per-app config**. First proven on `kyra_api`
(VEN-937/940).

## How it works

```
        GitHub (orchestration, PR checks)  ──dispatch jobs by label──►  your Mac
                                                                          │
  ┌───────────────────────────────────────────────────────────────────┐ │
  │  Docker Desktop                                                     │ │
  │   pair = [ runner ]◄──shares netns──►[ dind ]   (× N in parallel)   │ │
  │            actions agent              nested dockerd:               │ │
  │            (job steps run here)       services:, supabase, docker   │ │
  └───────────────────────────────────────────────────────────────────┘ │
```

Each **pair** is an Actions runner sharing its own dind's network namespace, so the
job's `services:` publish to `localhost` exactly like a hosted `ubuntu-latest`
runner — the app's `ci.yml` needs no changes beyond `runs-on: [self-hosted, …]`.
Runners are **ephemeral** (one job, then re-register). Run **N pairs** for
concurrency.

```
ci-runner/
  images/base/Dockerfile      # stack-agnostic: actions runner, docker CLI, tool cache, tzdata, python3
  images/rails/Dockerfile     # + postgresql-client, chromium, ruby build deps   (kyra, pamm, postcard)
  images/expo/Dockerfile      # + Node, watchman, …  (cooldown)  — STUB
  images/godot/Dockerfile     # + Godot + export templates  (riftling, terminal-ai)  — STUB
  compose.yaml                # parameterized runner+dind pair
  entrypoint.sh               # generic ephemeral registration (baked into base)
  bin/ci-runner               # launcher
  apps/<app>.env              # per-app: REPO_OWNER, REPO_NAME, STACK, RUNNER_LABELS, RUNNER_NAME
  apps/<app>.secret.env       # per-app PAT (gitignored)
```

## Prerequisites

- **Docker Desktop** running. **≥ 8 GB** memory for heavy stacks (Rails
  `supabase-parity` ~10 containers, `system-test` headless Chromium).
- A **fine-grained GitHub PAT** per app, scoped to that app's repo with
  **Administration: Read and write** (to mint runner registration tokens).

## Sizing & resource limits

Every pair (runner + dind) runs in the **one shared Docker Desktop VM**, so max concurrent
jobs across all apps == total registered pairs — there is no cross-app semaphore. On an
**8-CPU / 16 GB VM** the supported ceiling is **~3 concurrent Rails pairs**; beyond that the
VM swaps and starved runner agents miss their GitHub heartbeat, which surfaces as
**"The self-hosted runner lost communication with the server"** (a job-level failure that
spares light jobs and strikes heavy Ruby/Node steps). Keep each Rails app at **1 pair** until
the VM is enlarged (Docker Desktop → Settings → Resources → Memory).

Each pair is capped so one job can't swamp the VM — a cgroup hard limit turns a VM-wide
swap-stall (which fails *every* runner at once) into a localized OOM of just the over-budget
job. Defaults are Rails-sized; override per app in `apps/<app>.env`:

| var           | default | caps                                    |
|---------------|---------|-----------------------------------------|
| `RUNNER_MEM`  | `3g`    | runner memory (rspec + Chromium)        |
| `DIND_MEM`    | `2g`    | dind memory (job `services:` + builds)  |
| `RUNNER_CPUS` | `2.5`   | runner CPUs                             |
| `DIND_CPUS`   | `1.5`   | dind CPUs                               |

Expo/godot pairs set lighter values (`RUNNER_MEM=2g`, `DIND_MEM=1g`, `*_CPUS` 1.5/1) in their
env. `CI_RUNNER_REPLICAS` in `apps/<app>.env` sets the default pair count for `up`/`reset`
(kyra is pinned to `1`). Changing any limit takes effect on the next `bin/ci-runner <app> up`
(recreates the pairs).

## Run runners for an app

```bash
cd ci-runner
cp apps/secret.env.example apps/kyra.secret.env    # paste the PAT into GITHUB_PAT
bin/ci-runner kyra up 2                             # build base+rails once, start 2 parallel pairs
```

Verify on GitHub → the app repo → Settings → Actions → Runners (`kyra-mac-runner-1/2`,
Idle). Manage with:

```bash
bin/ci-runner kyra status | logs [i] | down
bin/ci-runner kyra up 3        # scale (size N to RAM; each pair carries its own dind + job containers)
bin/ci-runner kyra reset 2     # clean recovery: down → clear stale GitHub registrations → up
```

Use **`reset`** if runners get stuck after a restart/cutover (containers up but
unregistered, or jobs failing mid-run): reusing the same runner names triggers GitHub
"session already exists" conflicts, and `reset` clears them and re-registers fresh.

The app's `ci.yml` jobs must target the app's labels, e.g.
`runs-on: [self-hosted, linux, kyra]`.

## Add an app

1. `apps/<app>.env` — `REPO_OWNER`, `REPO_NAME`, `STACK` (rails|expo|godot),
   `RUNNER_LABELS`, `RUNNER_NAME` (name prefix).
2. `cp apps/secret.env.example apps/<app>.secret.env` and set its PAT.
3. Make the app's `ci.yml` target the labels, then `bin/ci-runner <app> up N`.

## Add a stack

Add `images/<stack>/Dockerfile` (`FROM ${BASE_IMAGE}`, add the stack's toolchain),
then set `STACK=<stack>` in the app configs that use it. The `rails` image is the
worked example; `expo`/`godot` are stubs to fill against those apps' workflows.

## Security

- **One PAT per app**, in the gitignored `apps/<app>.secret.env`, scoped to one repo
  with only `Administration: Read and write`.
- **Ephemeral + private repos**: a runner takes one job then re-registers; no state
  bleeds between jobs, and fork-PR risk doesn't apply to private repos.
- **dind is privileged but never exposed** (its API listens only inside the shared
  netns; no host port is published).

See [docs/runbooks/self-hosted-ci-runner.md](../docs/runbooks/self-hosted-ci-runner.md).
