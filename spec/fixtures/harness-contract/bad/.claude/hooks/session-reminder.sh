#!/usr/bin/env bash
# Fixture: the VEN-1392 defect at both shapes. The multi-line case is the one an
# earlier version of the checker missed — it confirmed a predicate existed but
# never inspected its tiers, so this line must stay multi-line to be a real test.
psql -t -A -c "SELECT rule_text FROM agent_harness.rules WHERE app IN ('global', '${HARNESS_APP:-fixture}') AND role = 'universal';"
psql -t -A -c "SELECT rule_text FROM agent_harness.rules
    WHERE app IN ('global', '${HARNESS_APP:-fixture}')
      AND severity = 'critical'
    ORDER BY (app = 'global') DESC, id ASC;"
