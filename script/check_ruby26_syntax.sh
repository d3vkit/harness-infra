#!/usr/bin/env bash
# check_ruby26_syntax.sh — hold the Ruby 2.6 syntax floor for the host-side scripts.
#
# WHY (VEN-1321): global-common.md *mandates* script/archive_done_linear_tickets.rb as the
# recovery path when the shared Linear ticket cap blocks a required ticket create, and promises
# it needs "only Ruby". Agents reach it through non-interactive shells, which resolve a bare
# `ruby` to macOS's /usr/bin/ruby — 2.6.10 — not to an asdf/rbenv shim. One 3.1-only construct
# (`{ query:, variables: }`) fails at *parse* time, so no in-script version guard can report it:
# the tool just looks broken at the single moment the cap makes it mandatory.
#
# The `Ruby syntax` CI step runs `ruby -c` under 3.3, which parses that construct happily, so it
# is structurally incapable of catching the regression. This is the check that can fail on it.
#
# SCOPE: syntax only. This does not claim every script RUNS on system Ruby — build_global_rules.rb
# needs the `pg` gem, which system Ruby has no business carrying. Parse-time is the failure that
# hides; a missing gem announces itself with a resolvable error.
#
# The interpreter is a pinned image rather than whatever `ruby` the host happens to expose, for
# the same reason the shellcheck step pins one: the version that gates a PR is then identical to
# the one this was verified against, on every machine and in CI. 2.6.10 is the final 2.6 release
# and the version macOS ships.
#
# Usage:
#   script/check_ruby26_syntax.sh                 # default: script/*.rb
#   script/check_ruby26_syntax.sh path/to/one.rb  # explicit targets (used by the CI self-test)
#
# Exit: 0 when every target parses on 2.6; 1 when any target fails or no target was found.

set -euo pipefail

RUBY26_IMAGE="ruby:2.6.10-slim"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

targets=()
if [ "$#" -gt 0 ]; then
  targets=("$@")
else
  # Every .rb here is host-side and agent-invoked, so all of them carry the same
  # non-interactive-shell exposure. Globbing the directory rather than keeping a hand-written
  # list means a newly added script cannot quietly opt out of the floor. If one ever genuinely
  # needs 3.x, this check going red is the right place to make that call deliberately.
  while IFS= read -r f; do targets+=("$f"); done < <(find script -maxdepth 1 -name '*.rb' | sort)
fi

if [ "${#targets[@]}" -eq 0 ]; then
  echo "check_ruby26_syntax: no Ruby files to check — expected at least one" >&2
  exit 1
fi

for f in "${targets[@]}"; do
  if [ ! -f "$f" ]; then
    echo "check_ruby26_syntax: no such file: $f" >&2
    exit 1
  fi
done

# One container for the whole set: `ruby -c` per file, but do not stop at the first failure —
# reporting every offending file beats making someone re-run the gate once per mistake.
output="$(docker run --rm -v "$ROOT:/mnt" -w /mnt "$RUBY26_IMAGE" \
  ruby -e '
    failed = []
    ARGV.each do |path|
      out = IO.popen(["ruby", "-c", path], err: [:child, :out], &:read)
      if $?.success?
        puts "  ok   #{path}"
      else
        failed << path
        puts "  FAIL #{path}"
        out.each_line { |l| puts "         #{l.rstrip}" }
      end
    end
    exit(failed.empty? ? 0 : 1)
  ' "${targets[@]}" 2>&1)" && status=0 || status=$?

echo "$output"

if [ "$status" -ne 0 ]; then
  cat >&2 <<EOF

check_ruby26_syntax: FAILED — the above will not parse on Ruby 2.6 (${RUBY26_IMAGE}).

macOS ships 2.6.10 as /usr/bin/ruby, and that is what a non-interactive shell gets. A file that
cannot parse there is not a style nit: agents invoke these scripts from non-interactive shells,
and a parse error surfaces as a broken tool rather than a fixable environment problem. Rewrite
the construct in 2.6-compatible syntax (the usual culprit is a 3.1 shorthand hash — write
\`{ query: query }\`, not \`{ query: }\`).
EOF
  exit 1
fi

echo "ruby 2.6 syntax floor: OK (${#targets[@]} file(s) parse on ${RUBY26_IMAGE})"
