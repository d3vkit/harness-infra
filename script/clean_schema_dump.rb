#!/usr/bin/env ruby
# frozen_string_literal: true

# clean_schema_dump.rb — filter a pg_dump of the agent_harness schema into a form that is
# safe to apply via the `pg` gem's conn.exec, and safe against the harness DB's Postgres 16.
#
# Usage (see the header of db/harness_schema.sql for the full rebuild command):
#   docker exec -e PGPASSWORD=postgres agent-harness-infra-harness-db-1 \
#     pg_dump -U postgres -d postgres --schema-only --schema=agent_harness \
#     --no-owner --no-privileges | ruby script/clean_schema_dump.rb > db/harness_schema.sql
#
# Reads a dump on stdin, writes the cleaned dump on stdout. Two filters, each guarding a
# real failure that has bitten this harness:
#
#   1. `\restrict` / `\unrestrict` — pg_dump >= 16.14 wraps output in these. They are psql
#      meta-commands, NOT SQL. ensure_schema applies this file with conn.exec(file.read)
#      through the pg gem, which speaks only SQL and dies on a leading backslash.
#
#   2. `SET transaction_timeout` — PostgreSQL 17+ only. The harness DB is postgres:16
#      (compose.yaml), which rejects it with "unrecognized configuration parameter".
#      Emitted when the dump is taken by a PG17 client against the PG16 server.
#
# Deliberately a filter rather than a rewriter: it drops known-bad lines and passes
# everything else through untouched, so a schema change never needs a change here.

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

DROP_PREFIXES = ["\\restrict", "\\unrestrict"].freeze
DROP_PATTERN  = /\A\s*SET\s+transaction_timeout\b/i

dropped = Hash.new(0)

ARGF.each_line do |line|
  if DROP_PREFIXES.any? { |p| line.start_with?(p) }
    dropped[line.split.first] += 1
    next
  end
  if line.match?(DROP_PATTERN)
    dropped["SET transaction_timeout"] += 1
    next
  end
  print line
end

dropped.each { |what, n| warn "clean_schema_dump: dropped #{n} #{what} line(s)" }
