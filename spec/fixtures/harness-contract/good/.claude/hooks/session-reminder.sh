#!/usr/bin/env bash
# Fixture: tier-complete reader. Single-line and multi-line predicates, both
# carrying the stack tier.
psql -t -A -c "SELECT rule_text FROM agent_harness.rules WHERE app IN ('global', 'global-${HARNESS_STACK:-rails}', '${HARNESS_APP:-fixture}') AND role = 'universal';"
psql -t -A -c "SELECT rule_text FROM agent_harness.rules
    WHERE app IN ('global', 'global-${HARNESS_STACK:-rails}', '${HARNESS_APP:-fixture}')
      AND severity = 'critical'
    ORDER BY (app = 'global') DESC, (app LIKE 'global-%') DESC, id ASC;"
