#!/usr/bin/env ruby
# frozen_string_literal: true

# verify_global_rules.rb — checks on the canonical rule sources and the seeder that writes them.
#
# Runs in CI (.github/workflows/ci.yml) and locally:
#   ruby script/verify_global_rules.rb            # file checks only, no DB needed
#   ruby script/verify_global_rules.rb --round-trip   # also seeds a DB and reads it back
#
# --round-trip requires PGHOST/PGPORT/... pointing at a THROWAWAY database. It calls the real
# seeder, which DELETEs and rewrites every global* tier — never point it at the shared harness DB
# unless you mean to reseed it (that is the seeder's normal job, but this script also asserts
# idempotency by running it twice).
#
# It deliberately reuses the seeder's own collect_rules/infer_severity by requiring it (the seeder
# guards its entry point with `rebuild! if __FILE__ == $PROGRAM_NAME`, so requiring is inert).
# Reimplementing the parse here would let the check drift away from the thing it checks.

require "json"
require "pathname"
require_relative "build_global_rules"

# An unrecognised flag must never be ignored. `--round-trip` mistyped as `--roundtrip` would
# otherwise silently run the file checks alone and still print PASS — a green that asserts far
# less than the reader believes, which is the failure-aliased-to-success shape this repo keeps
# correcting (VEN-1310).
KNOWN_FLAGS = ["--round-trip"].freeze
unknown = ARGV - KNOWN_FLAGS
unless unknown.empty?
  abort "verify_global_rules: unknown argument(s): #{unknown.join(' ')}\nusage: ruby script/verify_global_rules.rb [--round-trip]"
end

# --round-trip calls the real seeder, which DELETEs and rewrites every global* tier. The seeder's
# DB defaults (inherited via require) are the SHARED harness DB at 127.0.0.1:55432 — so running
# this with no PG* env set would reseed production and, worse, assert idempotency by seeding it
# twice. Refuse the shared port unless the caller says explicitly that they mean it.
if ARGV.include?("--round-trip")
  shared = DB[:port] == 55432 || DB[:host] == "harness-db"
  if shared && ENV["ALLOW_SHARED_HARNESS_DB"] != "1"
    abort <<~MSG
      verify_global_rules: refusing --round-trip against the shared harness DB.

        target: #{DB[:host]}:#{DB[:port]} (database #{DB[:dbname]})

      --round-trip seeds twice to assert idempotency, so it must run against a THROWAWAY database.
      Start one and point at it:

        docker run -d --rm --name harness-verify -e POSTGRES_PASSWORD=postgres \\
          -e POSTGRES_USER=postgres -e POSTGRES_DB=postgres -p 55499:5432 postgres:16
        PGHOST=127.0.0.1 PGPORT=55499 ruby script/verify_global_rules.rb --round-trip

      If you genuinely mean to target the shared DB, set ALLOW_SHARED_HARNESS_DB=1. To simply
      reseed it, run script/build_global_rules.rb instead — that is its job.
    MSG
  end
end

failures = []
def check(failures, desc)
  ok, detail = yield
  puts format("  %-4s %s%s", ok ? "ok" : "FAIL", desc, detail ? " — #{detail}" : "")
  failures << desc unless ok
end

puts "rule sources:"

TIERS.each do |tier, path|
  check(failures, "#{tier}: source exists") { [path.exist?, path.exist? ? nil : path.to_s] }
  next unless path.exist?

  rules = collect_rules(tier, path)
  check(failures, "#{tier}: parses to at least one rule") { [!rules.empty?, "#{rules.size} rules"] }

  # Under a `## ` heading the seeder keeps ONLY lines matching its bullet regex and silently
  # discards everything else. So any non-blank, non-bullet line there is content the author
  # believes is a rule and that no agent will ever read. Two real failure modes:
  #   - a bullet split across lines: the seeder keeps the first line and drops the rest, seeding
  #     a truncated rule (e.g. "Push your own branch" instead of the whole 3k-char rule);
  #   - prose written under a heading expecting it to become a rule — it never does.
  #
  # Counting bullets and comparing to rules cannot catch either: the counter and the seeder share
  # one regex, so they agree on the same wrong answer. Checking for orphans is the real invariant.
  orphans = []
  heading = nil
  File.read(path).each_line.with_index(1) do |line, lineno|
    if line.match?(/^## /) then heading = line; next end
    next unless heading
    next if line.strip.empty?
    next if line.match?(/^\s*(?:[-*]|\d+\.)\s+\S/)
    orphans << lineno
  end
  check(failures, "#{tier}: no line under a heading is silently discarded") do
    [orphans.empty?, orphans.empty? ? "#{rules.size} rules" : "line(s) #{orphans.join(', ')} are neither blank nor a bullet, so the seeder drops them"]
  end

  check(failures, "#{tier}: no rule text is empty or truncated") do
    bad = rules.reject { |r| r[:rule_text].to_s.strip.length > 10 }
    [bad.empty?, bad.empty? ? nil : "#{bad.size} suspiciously short"]
  end

  check(failures, "#{tier}: severity is a known value") do
    bad = rules.map { |r| r[:severity] }.uniq - %w[critical standard advisory]
    [bad.empty?, bad.empty? ? nil : bad.join(",")]
  end
end

puts "invariants:"

check(failures, "global-invariants.json exists") { [INVARIANTS_JSON.exist?, nil] }

if INVARIANTS_JSON.exist?
  rows = nil
  check(failures, "global-invariants.json parses as JSON") do
    begin
      rows = JSON.parse(File.read(INVARIANTS_JSON))
      [rows.is_a?(Array), "#{rows.size} entries"]
    rescue JSON::ParserError => e
      [false, e.message[0, 80]]
    end
  end

  if rows.is_a?(Array)
    required = %w[description enforcement consequence source_file tags]
    check(failures, "every invariant has the required keys") do
      bad = rows.reject { |r| required.all? { |k| r.key?(k) } }
      [bad.empty?, bad.empty? ? nil : "#{bad.size} missing keys"]
    end

    check(failures, "every invariant's source_file resolves") do
      bad = rows.map { |r| r["source_file"] }.compact.uniq.reject { |f| ROOT.join(f).exist? }
      [bad.empty?, bad.empty? ? nil : bad.join(", ")]
    end

    check(failures, "every invariant's tags is a non-empty array") do
      bad = rows.reject { |r| r["tags"].is_a?(Array) && !r["tags"].empty? }
      [bad.empty?, bad.empty? ? nil : "#{bad.size} bad"]
    end
  end
end

if ARGV.include?("--round-trip")
  puts "round-trip (seeding #{ENV.fetch('PGHOST', '?')}:#{ENV.fetch('PGPORT', '?')}):"

  expected = TIERS.to_h { |tier, path| [tier, collect_rules(tier, path).size] }

  conn = PG.connect(DB)

  seed_counts = lambda do
    rebuild_rules!(conn)
    rebuild_invariants!(conn)
    TIERS.keys.to_h do |tier|
      n = conn.exec_params("SELECT count(*) FROM agent_harness.rules WHERE app = $1", [tier])[0]["count"].to_i
      [tier, n]
    end
  end

  first = seed_counts.call
  check(failures, "seeded row counts match the parsed sources") do
    [first == expected, "#{first.values.sum} rows"]
  end

  # rebuild_rules! is DELETE + N INSERTs per tier with no transaction wrapper; a second run must
  # land on exactly the same counts rather than duplicating.
  second = seed_counts.call
  check(failures, "seeder is idempotent across two runs") do
    [first == second, first == second ? nil : "#{first.inspect} then #{second.inspect}"]
  end

  inv = conn.exec("SELECT count(*) FROM agent_harness.invariants WHERE app = 'global'")[0]["count"].to_i
  check(failures, "invariants seeded without duplicating") do
    [inv == JSON.parse(File.read(INVARIANTS_JSON)).size, "#{inv} rows"]
  end

  # The tier predicate every agent actually reads.
  n = conn.exec(
    "SELECT count(*) FROM agent_harness.rules WHERE app IN ('global','global-rails','postcard')"
  )[0]["count"].to_i
  check(failures, "a rails app's tier query returns rules") { [n.positive?, "#{n} rules"] }

  conn.close
end

puts
if failures.empty?
  puts "PASS — #{TIERS.size} tiers verified"
  exit 0
else
  puts "FAIL — #{failures.size} check(s) failed:"
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
