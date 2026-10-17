#!/usr/bin/env bash
# Runs home/fleet-deploy.sh against stubbed hosts, nix, cache and GitHub
# (./stub.sh), with real git in temporary repositories, and checks what it did.
# fleet-deploy acts on the Pis, and these are its guards: hosts in their
# nightly order, a typed name where the brief says `be there` or there is no
# brief, staged reboots included, holds left alone and reachable without
# GitHub, the first failure or newly failed unit stopping the rest, the wait
# for the cache through GitHub's errors, a reboot seen to happen, the window's
# own reboot waited for, ssh kept off the prompts' stdin, and main moving
# underneath it.
# scripts/preflight.sh runs it after the night-shift dispatcher's tests.
#
# Each case is a directory of its own, $FD, holding the hosts' state and the
# stubs' answers, and a clone of a two-commit repository whose origin's path
# names nnorx/nix-config, as fleet-deploy checks. Answers to its prompts come
# on stdin, a line each.
#
# One line per case, then the failures. FLEET_DEPLOY_SCRIPT names the script
# under test, by default this checkout's. FLEET_DEPLOY_TESTS_KEEP=1 keeps every
# case's directory, with the stubs' log and the script's output.
set -euo pipefail

root=$(realpath -- "$(dirname -- "$0")/../..")
here=$root/tests/fleet-deploy
script=$(realpath -- "${FLEET_DEPLOY_SCRIPT:-$root/home/fleet-deploy.sh}")

work=$(mktemp -d)
if [[ -n ${FLEET_DEPLOY_TESTS_KEEP:-} ]]; then
  echo "fleet-deploy tests: keeping $work"
else
  trap 'rm -rf "$work"' EXIT
fi

bin=$work/bin
mkdir -p "$bin"
for tool in ssh ssh-add nix curl sleep date; do
  printf '#!%s\nexec %q %q %s "$@"\n' "$BASH" "$BASH" "$here/stub.sh" "$tool" >"$bin/$tool"
  chmod +x "$bin/$tool"
done

# The origin, with the commit the hosts run and main on top of it.
export GIT_CONFIG_GLOBAL=$work/gitconfig GIT_CONFIG_NOSYSTEM=1
git config --global user.name test
git config --global user.email test@example.invalid
git config --global init.defaultBranch main
origin=$work/nnorx/nix-config.git
git init --quiet --bare "$origin"
git clone --quiet "$origin" "$work/seed" 2>/dev/null
git -C "$work/seed" commit --quiet --allow-empty -m running
git -C "$work/seed" commit --quiet --allow-empty -m main
git -C "$work/seed" push --quiet origin main
old=$(git -C "$work/seed" rev-parse HEAD^)
main=$(git -C "$work/seed" rev-parse HEAD)
other=0123456789abcdef0123456789abcdef01234567

pis=(lifeline core4 core5)
toplevel() { printf '/nix/store/%-32s-nixos-system-%s' "$1" "$1" | tr ' ' x; }
hash() { toplevel "$1" | cut -c12-43; }

c="" status=0
begin() {
  c=$work/$1
  mkdir -p "$c"
  git clone --quiet "$origin" "$c/checkout"
  echo "$main" >"$c/main"
  echo "completed success" >"$c/run"
  echo 12:00 >"$c/now"
  : >"$c/log"
  jq -n --arg l "$(toplevel lifeline)" --arg c4 "$(toplevel core4)" --arg c5 "$(toplevel core5)" \
    '{core4: {at: "04:00", toplevel: $c4}, core5: {at: "05:00", toplevel: $c5}, lifeline: {at: "03:00", toplevel: $l}}
    | map_values(. + {window: {lower: "02:30", upper: "06:00"}, tz: "America/New_York"})' \
    >"$c/hosts.json"
  brief routine
  for h in "${pis[@]}"; do
    mkdir -p "$c/$h"
    echo "$old" >"$c/$h/revision"
    echo "$old" >"$c/$h/next-boot"
    echo no >"$c/$h/staged"
    echo no >"$c/$h/hold"
    echo none >"$c/$h/failed"
  done
}

# brief <level> [host]: a brief whose finding for host (default lifeline) has
# that level.
brief() {
  jq -n --arg level "$1" --arg h "${2:-lifeline}" '{
    verdict: {level: $level},
    configs: [{name: "lifeline", state: "changed"}, {name: "core4", state: "changed"}, {name: "core5", state: "changed"}],
    hosts: {($h): {findings: [{level: $level, area: "stub"}]}},
    plan: []}' >"$c/brief.json"
}

# run [args...] <<<answers: the script, from the case's checkout, its output
# in $c/out and its exit code in $status.
run() {
  status=0
  (cd "$c/checkout" && FD=$c FLEET_DEPLOY_KEY=$c/key PATH=$bin:$PATH \
    "$BASH" -euo pipefail "$script" "$@") >"$c/out" 2>&1 || status=$?
}

failures=()
fail() { failures+=("$name: $*"); }
upgrades() { grep -c "deploy@$1 upgrade" "$c/log" || true; }
expect_status() { [[ $status == "$1" ]] || fail "exit $status, wanted $1"; }
expect_out() { grep -qF -- "$1" "$c/out" || fail "no '$1' in the output"; }
expect_upgrades() {
  local h
  for h in "${pis[@]}"; do
    local want=0
    [[ " $* " == *" $h "* ]] && want=1
    [[ $(upgrades "$h") == "$want" ]] || fail "$h upgraded $(upgrades "$h") times, wanted $want"
  done
}

case_() {
  name=$1
  local before=${#failures[@]}
  begin "$name"
  "$2"
  if [[ ${#failures[@]} == "$before" ]]; then echo "ok   $name"; else echo "FAIL $name"; fi
}

# --- Cases -------------------------------------------------------------------

t_routine() {
  run <<<$'y\ny\ny'
  expect_status 0
  expect_upgrades lifeline core4 core5
  # In the nightly order, and one brief for the one revision they all run.
  [[ $(grep -o 'deploy@[a-z0-9]* upgrade' "$c/log" | tr '\n' ' ') == "deploy@lifeline upgrade deploy@core4 upgrade deploy@core5 upgrade " ]] ||
    fail "upgraded out of order"
  [[ $(grep -c '^nix run' "$c/log") == 1 ]] || fail "preflight ran more than once"
  for h in "${pis[@]}"; do [[ $(<"$c/$h/revision") == "$main" ]] || fail "$h not on main"; done
}

t_be_there_needs_name() {
  brief "be there"
  run <<<$'y\ny\ny'
  expect_status 0
  expect_upgrades core4 core5
  expect_out "skipped."
}

t_be_there_typed() {
  brief "be there"
  run lifeline <<<"lifeline"
  expect_status 0
  expect_upgrades lifeline
}

t_review_takes_y() {
  brief review
  run lifeline <<<"y"
  expect_status 0
  expect_upgrades lifeline
}

t_no_answer_skips() {
  run lifeline </dev/null
  expect_status 0
  expect_upgrades
}

t_held_left_alone() {
  echo yes >"$c/core4/hold"
  run <<<$'y\ny'
  expect_status 0
  expect_upgrades lifeline core5
  expect_out "fleet-deploy release core4"
}

t_on_main_left_alone() {
  echo "$main" >"$c/lifeline/revision"
  echo "$main" >"$c/lifeline/next-boot"
  run lifeline </dev/null
  expect_status 0
  expect_upgrades
  expect_out "already on main"
}

t_failure_stops_the_rest() {
  touch "$c/lifeline/upgrade-fails"
  run <<<$'y\ny\ny'
  expect_status 1
  expect_upgrades lifeline
  expect_out "stand-in upgrade failed"
}

t_failed_units_stop_the_rest() {
  echo "unbound.service" >"$c/lifeline/fails-during"
  run <<<$'y\ny\ny'
  expect_status 1
  expect_upgrades lifeline
  expect_out "failed during the deploy: unbound.service"
}

t_failed_after_reboot_stops() {
  touch "$c/lifeline/kernel"
  echo "unbound.service" >"$c/lifeline/fails-during"
  run <<<$'y\ny\ny\ny'
  expect_status 1
  expect_upgrades lifeline
  expect_out "failed during the deploy: unbound.service"
}

# A unit failed before the deploy is shown, and does not stop the rest.
t_failed_before_goes_on() {
  echo "backup.service" >"$c/lifeline/failed"
  run <<<$'y\ny\ny'
  expect_status 0
  expect_upgrades lifeline core4 core5
  expect_out "still failed, as before the deploy: backup.service"
}

# Real ssh reads stdin unless given -n, and so does the stub: answers given up
# front must still reach the prompts.
t_ssh_leaves_answers() {
  run <<<$'y\ny\ny'
  grep '^ssh ' "$c/log" | grep -qv -- ' -n ' && fail "an ssh without -n"
  expect_upgrades lifeline core4 core5
}

t_off_main_needs_name() {
  echo "$other" >"$c/lifeline/revision"
  run lifeline <<<"y"
  expect_upgrades
  expect_out "not a commit on main"
  grep -q '^nix run' "$c/log" && fail "briefed a revision not on main"
  true
}

t_preflight_fails_needs_name() {
  touch "$c/preflight-fails"
  run lifeline <<<"y"
  expect_upgrades
  expect_out "preflight failed above"
}

# The empty brief a failed preflight leaves is not read for the next host on
# the same revision.
t_failed_brief_not_reused() {
  touch "$c/preflight-fails"
  run lifeline core4 <<<$'y\ny'
  expect_status 0
  expect_upgrades
  [[ $(grep -c '^nix run' "$c/log") == 2 ]] || fail "preflight not run again for core4"
}

t_unreadable_brief_is_be_there() {
  echo 'not json' >"$c/brief.json"
  run lifeline <<<"y"
  expect_upgrades
  expect_out "the brief for lifeline: be there"
}

t_waits_for_cache() {
  echo 3 >"$c/misses-$(hash lifeline)"
  echo "in_progress -" >"$c/run"
  run lifeline <<<"y"
  expect_status 0
  expect_upgrades lifeline
  expect_out "not in the cache yet; cache.yml is in_progress"
}

t_cache_run_done_without_it() {
  echo 99 >"$c/misses-$(hash lifeline)"
  echo "completed failure" >"$c/run"
  run lifeline <<<"y"
  expect_status 1
  expect_upgrades
  expect_out "cache.yml finished for main (failure)"
}

t_no_cache_run_gives_up() {
  echo 99 >"$c/misses-$(hash lifeline)"
  echo "none" >"$c/run"
  run lifeline <<<"y"
  expect_status 1
  expect_upgrades
  expect_out "no cache.yml run for main"
}

# GitHub not answering, its rate limit included, is not "no run": the wait
# goes on past the 5 minutes a missing run gets.
t_cache_api_errors_keep_waiting() {
  echo 20 >"$c/misses-$(hash lifeline)"
  echo "error" >"$c/run"
  run lifeline <<<"y"
  expect_status 0
  expect_upgrades lifeline
  expect_out "GitHub did not say"
}

t_staged_reboot() {
  touch "$c/lifeline/kernel"
  run lifeline <<<$'y\ny'
  expect_status 0
  expect_upgrades lifeline
  grep -q 'deploy@lifeline reboot' "$c/log" || fail "no reboot"
  [[ $(<"$c/lifeline/revision") == "$main" ]] || fail "lifeline did not boot main"
  expect_out "lifeline is down"
}

# ssh's 255 from a request that never arrived: the host never goes down.
t_lost_reboot_caught() {
  touch "$c/lifeline/kernel" "$c/lifeline/reboot-lost"
  run <<<$'y\ny\ny\ny'
  expect_status 1
  expect_upgrades lifeline
  expect_out "did not reboot"
}

# Inside the window the upgrade reboots by itself: no second reboot is asked
# for, and the next host waits until this one is back on main.
t_window_reboots_itself() {
  echo 03:15 >"$c/now"
  touch "$c/lifeline/kernel" "$c/lifeline/self-reboots"
  run lifeline <<<"y"
  expect_status 0
  expect_upgrades lifeline
  grep -q 'deploy@lifeline reboot' "$c/log" && fail "asked for a second reboot"
  expect_out "scheduled its own reboot"
  [[ $(<"$c/lifeline/revision") == "$main" ]] || fail "lifeline did not boot main"
}

t_window_crossing_midnight() {
  jq '.lifeline.window = {lower: "23:00", upper: "01:00"}' "$c/hosts.json" >"$c/hosts.next"
  mv "$c/hosts.next" "$c/hosts.json"
  echo 00:30 >"$c/now"
  touch "$c/lifeline/kernel" "$c/lifeline/self-reboots"
  run lifeline <<<"y"
  expect_status 0
  expect_out "scheduled its own reboot"
}

# A staged main is a reboot into a new kernel: the brief still decides whether
# the name must be typed.
t_staged_only_needs_brief() {
  brief "be there"
  echo "$main" >"$c/lifeline/next-boot"
  echo yes >"$c/lifeline/staged"
  run lifeline <<<"y"
  expect_status 0
  grep -q 'deploy@lifeline reboot' "$c/log" && fail "rebooted on a y"
  grep -q '^nix run' "$c/log" || fail "no brief"
  true
}

t_staged_declined() {
  touch "$c/lifeline/kernel"
  run <<<$'y\nn\ny\ny'
  expect_status 0
  expect_upgrades lifeline core4 core5
  grep -q 'deploy@lifeline reboot' "$c/log" && fail "rebooted without a yes"
  expect_out "left staged"
}

t_staged_only_offers_reboot() {
  echo "$main" >"$c/lifeline/next-boot"
  echo yes >"$c/lifeline/staged"
  run lifeline <<<"y"
  expect_status 0
  expect_upgrades
  grep -q 'deploy@lifeline reboot' "$c/log" || fail "no reboot"
}

t_main_moved_stops() {
  echo "$other" >"$c/lifeline/upgrade-lands"
  run <<<$'y\ny\ny'
  expect_status 1
  expect_upgrades lifeline
  expect_out "not main"
}

t_gate_refused() {
  run gate </dev/null
  expect_status 1
  expect_out "gate is deployed by hand"
  grep -q '^ssh ' "$c/log" && fail "logged in somewhere"
  true
}

t_hold_verb() {
  run hold core5
  expect_status 0
  [[ $(<"$c/core5/hold") == yes ]] || fail "core5 not held"
  grep -q '^nix run' "$c/log" && fail "briefed for a hold"
  # From the checkout, not GitHub, so a hold works while either is broken.
  grep -q '^nix eval .*git+file://' "$c/log" || fail "the Pis not read from the checkout"
  grep -q 'github:' "$c/log" && fail "reached GitHub for a hold"
  true
}

t_hold_needs_no_fetch() {
  git -C "$c/checkout" remote set-url origin "$work/nnorx/nix-config-gone.git"
  run hold <<<""
  expect_status 0
  for h in "${pis[@]}"; do [[ $(<"$c/$h/hold") == yes ]] || fail "$h not held"; done
}

t_outside_checkout() {
  status=0
  (cd "$c" && FD=$c FLEET_DEPLOY_KEY=$c/key PATH=$bin:$PATH \
    "$BASH" -euo pipefail "$script") >"$c/out" 2>&1 || status=$?
  expect_status 64
  [[ -s $c/log ]] && fail "acted outside a checkout"
  true
}

for t in $(declare -F | awk '$3 ~ /^t_/ { print $3 }'); do
  case_ "${t#t_}" "$t"
done

if ((${#failures[@]} > 0)); then
  echo
  printf '%s\n' "${failures[@]}"
  exit 1
fi
