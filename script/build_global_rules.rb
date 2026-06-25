#!/usr/bin/env ruby
# frozen_string_literal: true

# build_global_rules.rb — the SOLE writer of the shared global rule tiers.
#
# The harness `rules` table is tiered by the `app` column. The cross-app "global"
# tiers are owned centrally, here, in harness-infra — NOT by any participating app:
#
#   global          common rules, applied to every app (rules/global-common.md)
#   global-rails    Rails-stack universal rules            (rules/global-rails.md)
#   global-expo     Expo/RN-stack universal rules          (rules/global-expo.md)
#   global-godot    Godot-stack universal rules            (rules/global-godot.md)
#   global-unreal   Unreal-Engine-stack universal rules    (rules/global-unreal.md)
#
# It also owns the shared `app='global'` invariants (rules/global-invariants.json).
# App seeders (script/build_harness_db.rb in each app) write ONLY their own
# `app=<name>` rows and must abort on any `global*` HARNESS_APP — they must never
# touch these tiers. See docs/runbooks/new-harness-integration.md.
#
# Usage (from anywhere — paths resolve relative to this repo):
#   PGHOST=127.0.0.1 PGPORT=55432 PGUSER=postgres PGPASSWORD=postgres \
#     ruby script/build_global_rules.rb
#
# Idempotent: re-running replaces every global* tier with the current file contents.

require "pg"
require "json"
require "pathname"

# Markdown/JSON sources contain non-ASCII (em-dashes, arrows). Force UTF-8.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

ROOT     = Pathname.new(__dir__).join("..").realpath
RULES_DIR = ROOT.join("rules")

# tier => source markdown file
TIERS = {
  "global"        => RULES_DIR.join("global-common.md"),
  "global-rails"  => RULES_DIR.join("global-rails.md"),
  "global-expo"   => RULES_DIR.join("global-expo.md"),
  "global-godot"  => RULES_DIR.join("global-godot.md"),
  "global-unreal" => RULES_DIR.join("global-unreal.md")
}.freeze

INVARIANTS_JSON = RULES_DIR.join("global-invariants.json")

DB = {
  host: ENV.fetch("PGHOST", "127.0.0.1"),
  port: Integer(ENV.fetch("PGPORT", "55432")),
  dbname: ENV.fetch("PGDATABASE", "postgres"),
  user: ENV.fetch("PGUSER", "postgres"),
  password: ENV.fetch("PGPASSWORD", "postgres")
}.freeze

# --- parsing (matches the app seeders so categories/severity stay consistent) ---

def infer_severity(text)
  down = text.downcase
  return "critical" if down.match?(/\bnever\b|\bmust\b|\balways\b|non.negotiable|do not\b|before writing/)
  return "advisory" if down.match?(/\bconsider\b|\bmay\b|\bmight\b|\bprefer\b|suggest/)
  "standard"
end

CATEGORY_MAP = {
  "toolchain"    => "toolchain",
  "engine"       => "toolchain",
  "workflow"     => "workflow",
  "architecture" => "architecture",
  "testing"      => "testing",
  "data"         => "data_model",
  "ui"           => "ui"
}.freeze

def map_category(heading)
  key = heading.to_s.downcase
  CATEGORY_MAP.each { |match, cat| return cat if key.include?(match) }
  "workflow"
end

def collect_rules(tier, path)
  abort "rules source not found: #{path}" unless path.exist?
  rel = path.relative_path_from(ROOT).to_s
  rules = []
  heading = nil
  File.read(path).each_line do |line|
    if line.match?(/^## /)
      heading = line.sub(/^## /, "").strip
      next
    end
    next unless heading
    m = line.match(/^\s*(?:[-*]|\d+\.)\s+(.+)/)
    next unless m
    text = m[1].strip
    next if text.empty?
    rules << {
      app: tier,
      role: "universal",
      category: map_category(heading),
      severity: infer_severity(text),
      rule_text: text,
      source_file: rel,
      source_heading: heading
    }
  end
  rules
end

# --- seeding ---

def rebuild_rules!(conn)
  total = 0
  TIERS.each do |tier, path|
    rules = collect_rules(tier, path)
    conn.exec_params("DELETE FROM agent_harness.rules WHERE app = $1", [tier])
    rules.each do |r|
      conn.exec_params(
        "INSERT INTO agent_harness.rules (app, role, category, severity, rule_text, source_file, source_heading) " \
        "VALUES ($1,$2,$3,$4,$5,$6,$7)",
        [r[:app], r[:role], r[:category], r[:severity], r[:rule_text], r[:source_file], r[:source_heading]]
      )
    end
    puts format("  rules:      %-13s %2d rules  (%s)", tier, rules.size, path.basename)
    total += rules.size
  end
  total
end

def rebuild_invariants!(conn)
  return 0 unless INVARIANTS_JSON.exist?
  rows = JSON.parse(File.read(INVARIANTS_JSON)) || []
  array_enc = PG::TextEncoder::Array.new
  conn.exec("DELETE FROM agent_harness.invariants WHERE app = 'global'")
  rows.each do |r|
    tags = r["tags"]
    tag_literal = tags.nil? ? nil : array_enc.encode(tags)
    conn.exec_params(
      "INSERT INTO agent_harness.invariants (app, description, enforcement, consequence, source_file, tags) " \
      "VALUES ('global',$1,$2,$3,$4,$5::text[])",
      [r["description"], r["enforcement"], r["consequence"], r["source_file"], tag_literal]
    )
  end
  puts format("  invariants: %-13s %2d rows   (%s)", "global", rows.size, INVARIANTS_JSON.basename)
  rows.size
end

def rebuild!
  puts "build_global_rules: target=#{DB[:host]}:#{DB[:port]} (SOLE writer of global* tiers)"
  conn = PG.connect(DB)
  rule_total = rebuild_rules!(conn)
  inv_total  = rebuild_invariants!(conn)
  puts "done: #{rule_total} global* rules + #{inv_total} global invariants seeded."
  conn.close
rescue PG::Error => e
  abort "database error: #{e.message}"
end

rebuild! if __FILE__ == $PROGRAM_NAME
