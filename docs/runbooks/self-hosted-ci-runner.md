# Runbook: self-hosted CI runners

Run any harness app's GitHub Actions CI on your own machine at $0 billed minutes.
The infra lives in [`ci-runner/`](../../ci-runner/) — a shared **base image** +
**per-stack toolchain images**, driven by thin **per-app config**. Centrally owned
here, like the shared Postgres and the global rule tiers.

## The model

- **Base image** (`ci-runner/images/base`) — stack-agnostic: the Actions runner
  agent, docker CLI, a writable tool cache, `tzdata`, `python3`, the
  ephemeral-registration entrypoint. ~90% of the work, shared by every app.
- **Per-stack image** (`ci-runner/images/<stack>`) — `FROM base`, adds the stack
  toolchain. `rails` is validated (kyra); `expo`/`godot` are stubs.
- **Per-app config** (`ci-runner/apps/<app>.env`) — `REPO_OWNER`, `REPO_NAME`,
  `STACK`, `RUNNER_LABELS`, `RUNNER_NAME`. The PAT is in `apps/<app>.secret.env`
  (gitignored).
- **Launcher** (`ci-runner/bin/ci-runner`) — builds base+stack once, then runs N
  parallel runner+dind pairs registered to the app's repo.

Each runner shares its own dind's network namespace, so the job's `services:` land
on `localhost` exactly like a hosted runner — the app's `ci.yml` only needs
`runs-on: [self-hosted, …, <app>]`.

## Run runners for an app

```bash
cd ci-runner
cp apps/secret.env.example apps/<app>.secret.env   # set GITHUB_PAT (Administration: r/w on the repo)
bin/ci-runner <app> up 2                            # 2 parallel pairs
bin/ci-runner <app> status | logs [i] | down
```

Confirm on GitHub → app repo → Settings → Actions → Runners (Idle). Keep the runners
up while you expect PRs (ephemeral — jobs queue/fail if all are down); before marking
the self-hosted checks *required*, make sure a runner is reliably up.

## Onboarding an app — checklist

1. `ci-runner/apps/<app>.env` (repo, stack, labels, name prefix).
2. `cp ci-runner/apps/secret.env.example ci-runner/apps/<app>.secret.env`; set the PAT.
3. If the stack image isn't ready (`expo`/`godot` are stubs), fill
   `ci-runner/images/<stack>/Dockerfile` and validate against the app's `ci.yml`.
4. Flip the app's `ci.yml` jobs to `runs-on: [self-hosted, linux, <app>]`
   (add `timeout-minutes`). Validate one job on the runner before requiring the checks.
5. `bin/ci-runner <app> up N`.

## Registering a new stack

If the app's framework isn't `rails`/`expo`/`godot`:

1. Add `ci-runner/images/<stack>/Dockerfile` (`FROM ${BASE_IMAGE}`, add toolchain).
2. Set `STACK=<stack>` in the relevant `apps/<app>.env`.
3. Build + validate one job on the runner before requiring checks.

## Notes / known follow-ups

- **Bake Node/Ruby into stack images** — ephemeral runners re-download them per job
  via `setup-node`/`setup-ruby`; under heavy parallel load that occasionally flakes.
  Baking them in removes the flake and speeds jobs.
- **Always-on host** — for a 24/7 gate without a laptop, the same stack runs on an
  Oracle Cloud "Always Free" ARM VM (arm64-native).
