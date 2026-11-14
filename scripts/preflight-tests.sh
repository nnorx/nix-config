#!/usr/bin/env bash
# The test suites scripts/preflight.sh runs beside its evaluations (its steps
# 1 and 2), one after another, stopping at the first that fails. They need no
# evaluation and hold little memory. Run from preflight's checkout, with its
# PATH and NIGHT_SHIFT_TYPES, and under --head too: they test the scripts in
# the working tree, not the commit's.
#
#   1. The brief's rules, against the hand-written cases in
#      tests/preflight-brief/ (scripts/test-preflight-brief.sh). A slip in a
#      rule changes verdicts with no error, so this fails the run instead.
#      Beside it, cve-scan's report, against tests/cve-scan-report/
#      (scripts/test-cve-scan-report.sh): the report says which whitelist
#      rules are dead, and a slip there gets a rule removed that still
#      suppresses something, or keeps one that suppresses nothing.
#   2. The night-shift dispatcher, pkgs/night-shift/, type-checked (Node runs
#      its TypeScript with the types stripped, unchecked), then run against
#      stubbed Linear, GitHub, ntfy and Claude (tests/night-shift/*.test.ts,
#      through harness.ts). It runs unattended, acts as Nick in Linear and
#      deletes worktrees and branches, and nothing else checks its guards once
#      a change lands. Then fleet-deploy, home/fleet-deploy.sh, against
#      stubbed hosts, nix and cache (tests/fleet-deploy/run.sh), since it
#      deploys the Pis, and the ratchets' exposure score
#      (scripts/test-ratchets-systemd.sh).
set -euo pipefail

step() {
  echo
  echo "==> $*"
}

step "brief rules"
# The brief uses the rules preflight was built with (PREFLIGHT_BRIEF), and
# those are what this tests.
"$BASH" scripts/test-preflight-brief.sh

step "cve-scan report rules"
"$BASH" scripts/test-cve-scan-report.sh

step "night-shift types"
tsc -p pkgs/night-shift --typeRoots "$NIGHT_SHIFT_TYPES"

step "night-shift dispatcher"
NIGHT_SHIFT_BASH="$BASH" node --test tests/night-shift/*.test.ts

step "fleet-deploy"
"$BASH" tests/fleet-deploy/run.sh

step "ratchets' exposure score"
"$BASH" scripts/test-ratchets-systemd.sh
