#!/usr/bin/env bash
# ACTIONS_RUNNER_HOOK_JOB_STARTED. Exported by entrypoint.sh (never by compose.yaml: if
# the variable came from compose against an image that predates this file, the runner
# could not find the hook and would FAIL EVERY JOB — which is exactly what a staged
# rollout or a SKIP_IMAGE_BUILD=1 recovery produces). Binding the variable to the image
# means the path and the script always version together.
#
# EXIT-0 BY CONSTRUCTION, three independent mechanisms:
#  1. `set +e` — the runner invokes hook scripts through the same handler as a `run:` step,
#     whose Linux default shell is `bash -e {0}`. A -e on the command line survives this
#     file's shebang; `set +e` is the only thing that clears it. NOT redundant with (2):
#     with only the trap the job is safe but the shell aborts at the first failure and the
#     rest of the scrub silently never runs. The trap protects the job; set +e protects
#     the cleanup.
#  2. `trap 'exit 0' EXIT` — pins the status however the shell leaves.
#  3. explicit `exit 0`.
set +e
set +u

trap 'exit 0' EXIT

# shellcheck source=../lib/scrub.sh
. /home/runner/lib/scrub.sh
harness_scrub job
exit 0
