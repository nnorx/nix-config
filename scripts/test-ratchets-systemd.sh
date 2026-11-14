#!/usr/bin/env bash
# Runs scripts/ratchets.sh on a stand-in unit of known exposure: at its cap
# the run passes, a tenth under it fails, and --tighten lowers a cap above it
# to the score. scripts/preflight-tests.sh runs this, last of its suites.
set -euo pipefail

root=$(realpath -- "$(dirname -- "$0")/..")
cd "$root"
# What systemd-analyze gives tests/ratchets-systemd/stand-in/demo.service. A
# nixpkgs bump that moves it rescores every unit.
score=8.2

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export RATCHETS_CAPS=$work/caps.json RATCHETS_STAND_INS=$root/tests/ratchets-systemd

# cap, the status the run should end with, and ratchets.sh's flags.
check() {
  local cap=$1 want=$2 status=0
  shift 2
  jq -n --argjson cap "$cap" '{prose: 1e9, comments: {nix: 100, sh: 100},
    shell: {default: 1e9, allow: {}}, systemd: {"stand-in/demo.service": $cap}}' >"$RATCHETS_CAPS"
  "$BASH" scripts/ratchets.sh "$@" >"$work/out" 2>&1 || status=$?
  if [[ $status != "$want" ]]; then
    cat "$work/out"
    echo "FAIL cap $cap${*:+ $*}: ended $status, not $want"
    exit 1
  fi
  echo "ok   cap $cap${*:+ $*}: $(grep -o 'stand-in.*' "$work/out")"
}

check "$score" 0
check 8.1 1
check 8.3 0 --tighten
if ! jq -e --argjson s "$score" '.systemd["stand-in/demo.service"] == $s' "$RATCHETS_CAPS" >/dev/null; then
  echo "FAIL --tighten left the cap at $(jq '.systemd[]' "$RATCHETS_CAPS"), not $score"
  exit 1
fi
