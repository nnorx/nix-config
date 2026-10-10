#!/usr/bin/env bash
# Runs scripts/preflight-brief.jq on each hand-written input under
# tests/preflight-brief/ and fails when its JSON brief differs from the case's
# expected.json. The verdict decides whether a merge needs Nick at hand, and a
# slip in a rule changes it with no error, so a rule change has to show which
# verdicts it moves. scripts/preflight.sh runs this as its first step.
#
# Each case is a directory holding input.json, in the shape preflight.sh hands
# the rules ({head, base, ok, files, versions, rev}, the hosts' facts as
# scripts/preflight-eval.nix reports them), and expected.json, the brief it
# should give. A new fact in preflight-eval.nix belongs in every case's hosts,
# or the rules read null there.
#
# --update rewrites every expected.json from the current rules instead. A PR
# that changes a rule runs it, and the diff of expected.json is the review: it
# shows exactly which verdicts moved.
#
# Needs only bash, jq and coreutils: the differences are printed by jq, path by
# path, so preflight needs nothing more on its PATH. PREFLIGHT_BRIEF names the
# rules, as it does for preflight; by default, the copy in this checkout.
set -euo pipefail

update=false
case ${1-} in
  "") ;;
  --update) update=true ;;
  *)
    echo "usage: test-preflight-brief [--update]" >&2
    exit 64
    ;;
esac

root=$(realpath -- "$(dirname -- "$0")/..")
rules=$(realpath -- "${PREFLIGHT_BRIEF:-$root/scripts/preflight-brief.jq}")
cd "$root"

shopt -s nullglob
inputs=(tests/preflight-brief/*/input.json)
if [[ ${#inputs[@]} -eq 0 ]]; then
  echo "no brief fixtures under tests/preflight-brief/"
  exit 0
fi

actual=$(mktemp)
trap 'rm -f "$actual"' EXIT

# Each leaf (a scalar, or an empty array or object) as "path: value", for the
# leaves one side has and the other does not.
# shellcheck disable=SC2016
leaf_diff='
  def step:
    if type == "number" then "[\(.)]"
    elif test("^[A-Za-z_][A-Za-z0-9_]*$") then ".\(.)"
    else ".[\(tojson)]" end;
  def leaves: [tostream | select(length == 2) | "\(.[0] | map(step) | join("")): \(.[1] | tojson)"];
  ($e[0] | leaves) as $e | ($a[0] | leaves) as $a
  | ($e - $a | map("  - " + .)) + ($a - $e | map("  + " + .)) | .[]'

failed=()
for input in "${inputs[@]}"; do
  dir=${input%/input.json}
  name=${dir##*/}
  if $update; then
    jq -S --arg format json -f "$rules" "$input" >"$dir/expected.json"
    echo "updated $name"
    continue
  fi
  jq -S --arg format json -f "$rules" "$input" >"$actual"
  if [[ ! -f $dir/expected.json ]]; then
    echo "FAIL $name: no expected.json; run with --update to write it"
    failed+=("$name")
  elif [[ $(jq -S . "$dir/expected.json") != "$(jq -S . "$actual")" ]]; then
    echo "FAIL $name: the brief differs from expected.json (- expected, + now)"
    jq -rn --slurpfile e "$dir/expected.json" --slurpfile a "$actual" "$leaf_diff"
    failed+=("$name")
  else
    echo "ok   $name"
  fi
done

if [[ ${#failed[@]} -gt 0 ]]; then
  echo "${#failed[@]} of ${#inputs[@]} brief fixtures failed: ${failed[*]}"
  exit 1
fi
$update || echo "all ${#inputs[@]} brief fixtures pass"
