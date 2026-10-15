#!/usr/bin/env bash
# Runs pkgs/night-shift/night-shift.sh against stubbed Linear, GitHub, ntfy and
# Claude, with real git in temporary repositories, and checks what it did. The
# dispatcher runs unattended every 10 minutes, acts as Nick in Linear, and
# deletes worktrees, branches and sessions; each guard on that was checked once,
# by hand or in a live run, and this checks them again on every change.
# scripts/preflight.sh runs it right after the brief's rules.
#
# Each case starts from an empty directory and runs the script the way it
# re-runs itself in child(), `$BASH -euo pipefail night-shift.sh <command>`,
# with an environment of the case's own (env -i): HOME, XDG_STATE_HOME,
# GIT_CONFIG_GLOBAL and NIGHT_SHIFT_PROJECTS all point inside it. The stubs
# under stubs/ come first on PATH, as curl, claude, systemd-run, bwrap and
# systemctl, and for work mode osascript, gh, caffeinate and launchctl, and
# say how they answer; everything else is real, git included. Nothing
# reaches the network, the real claude, or Nick's own state directory.
#
# A case on tidy or land_one gives its repository a literal GitHub origin, for
# github_repo(). One that starts an agent needs a fetch to work, so its origin
# is a local bare repository instead: `git remote get-url` expands insteadOf,
# so an insteadOf mapping would hide the GitHub URL from github_repo().
#
# One line per case, then the failures. NIGHT_SHIFT_SCRIPT names the script
# under test, by default the copy in this checkout, so a guard can be broken in
# a scratch copy to see its case fail. NIGHT_SHIFT_TESTS_KEEP=1 keeps every
# case's directory, its log.jsonl and the dispatcher's output, to look at.
# Needs bash, git, jq, coreutils, gnused, gawk, gnugrep and flock, and
# util-linux's script for the one case that answers on a terminal, which
# preflight's runtimeInputs carry.
set -euo pipefail

root=$(realpath -- "$(dirname -- "$0")/../..")
here=$root/tests/night-shift
script=$(realpath -- "${NIGHT_SHIFT_SCRIPT:-$root/pkgs/night-shift/night-shift.sh}")

work=$(mktemp -d)
if [[ -n ${NIGHT_SHIFT_TESTS_KEEP:-} ]]; then
  echo "night-shift tests: keeping $work"
else
  trap 'rm -rf "$work"' EXIT
fi

# The stubs, by the names the dispatcher calls, with this bash as their
# interpreter: writeShellApplication puts no bash on PATH.
bin=$work/bin
mkdir -p "$bin"
stub() {
  printf '#!%s\n%sexec %q -euo pipefail %q "$@"\n' "$BASH" "${3:-}" "$BASH" "$here/stubs/$2" >"$bin/$1"
  chmod +x "$bin/$1"
}
stub curl curl
stub claude claude
stub systemd-run scope 'export NS_STUB=systemd-run; '
stub bwrap scope 'export NS_STUB=bwrap; '
stub systemctl systemctl
stub osascript osascript
stub gh gh
stub caffeinate caffeinate
stub launchctl launchctl
path=$bin:$PATH
for tool in curl claude systemd-run bwrap systemctl osascript gh caffeinate launchctl; do
  [[ $(PATH=$path command -v "$tool") == "$bin/$tool" ]] || {
    echo "night-shift tests: $tool on PATH is not the stub" >&2
    exit 1
  }
done

# --- What each case has to hand ----------------------------------------------

# Set by begin for each case.
c="" status=0

# begin <dir>: the case's directory, with its own home, state directory,
# projects, Linear key and ntfy topic, a git config of its own, and power
# supplies that say it is on AC (battery to say otherwise).
begin() {
  c=$1
  mkdir -p "$c"/{home,state/night-shift,tmp,projects,remote,linear/issues,power/AC,power/BAT}
  echo Mains >"$c/power/AC/type"
  echo 1 >"$c/power/AC/online"
  echo Battery >"$c/power/BAT/type"
  cd "$c"
  : >"$c/log.jsonl"
  echo test-key >"$c/key"
  echo "https://ntfy.invalid/test-topic" >"$c/ntfy"
  cp "$here/fixtures/workspace.json" "$c/linear/workspace.json"
  git config --file "$c/gitconfig" user.name "Night Shift Test"
  git config --file "$c/gitconfig" user.email "test@example.invalid"
  git config --file "$c/gitconfig" init.defaultBranch main
  git config --file "$c/gitconfig" commit.gpgsign false
  git config --file "$c/gitconfig" advice.detachedHead false
}

# g <git args>: git as the dispatcher sees it.
g() {
  HOME=$c/home GIT_CONFIG_GLOBAL=$c/gitconfig GIT_CONFIG_NOSYSTEM=1 git "$@"
}

# ns [VAR=value...] <command> [args]: the dispatcher, from the case's
# directory, its exit status in $status and its output in $c/out. With $tty
# set, it runs on a terminal of its own, util-linux's script, which types $tty
# into it; otherwise its stdin is /dev/null and it has no terminal.
tty=""
ns() {
  local cmd=(env -i PATH="$path" HOME="$c/home" TMPDIR="$c/tmp" XDG_STATE_HOME="$c/state"
    GIT_CONFIG_GLOBAL="$c/gitconfig" GIT_CONFIG_NOSYSTEM=1 NS_CASE="$c"
    NIGHT_SHIFT_KEY_FILE="$c/key" NIGHT_SHIFT_NTFY_FILE="$c/ntfy"
    NIGHT_SHIFT_PROJECTS="$c/projects" NIGHT_SHIFT_POWER="$c/power" NIGHT_SHIFT_MAX=2
    NIGHT_SHIFT_STALL_HOURS=4 NIGHT_SHIFT_FAILED_RUNS=3)
  while [[ ${1-} == *=* ]]; do
    cmd+=("$1")
    shift
  done
  cmd+=("$BASH" -euo pipefail "$script" "$@")
  status=0
  if [[ -n $tty ]]; then
    printf '%s' "$tty" | SHELL=$BASH script -qec "$(printf '%q ' "${cmd[@]}")" /dev/null >>"$c/out" 2>&1 || status=$?
  else
    "${cmd[@]}" </dev/null >>"$c/out" 2>&1 || status=$?
  fi
}

# repo <name>: $c/projects/<name>, cloned from a bare $c/remote/<name>.git
# with one commit on main.
repo() {
  local seed=$c/tmp/seed-$1
  g init -q "$seed"
  echo "# $1" >"$seed/README.md"
  g -C "$seed" add README.md
  g -C "$seed" commit -q -m "first"
  g clone -q --bare "$seed" "$c/remote/$1.git"
  g clone -q "$c/remote/$1.git" "$c/projects/$1"
}

# issue <id> [jq filter]: the issue in Linear, from fixtures/issue.json.
issue() {
  jq --arg id "$1" ".id = \$id | ${2:-.}" "$here/fixtures/issue.json" >"$c/linear/issues/$1.json"
}

state() { jq -r .state.name "$c/linear/issues/$1.json"; }

# requests <jq filter>: how many logged requests match.
requests() { jq -s "map(select($1)) | length" "$c/log.jsonl"; }

# comments <id>: the comments posted on an issue, as one text.
comments() { jq -r '.comments.nodes[].body' "$c/linear/issues/$1.json"; }

# A worktree the dispatcher would have made for TST-1, with one commit on its
# branch, and the state file of an issue that has reached <phase>.
NAME=tst-1-fix-the-widget
BRANCH=worktree-$NAME
agent_worktree() {
  local r=$c/projects/demo phase=$1 started=${2:-$(date -u +%FT%TZ)}
  WT=$r/.claude/worktrees/$NAME
  g -C "$r" worktree add -q --no-track -b "$BRANCH" "$WT" origin/main
  echo widget >"$WT/widget.txt"
  g -C "$WT" add widget.txt
  g -C "$WT" commit -q -m "fix the widget"
  jq -n --arg repo "$r" --arg wt "$WT" --arg branch "$BRANCH" --arg name "$NAME" \
    --arg phase "$phase" --arg started "$started" \
    '{id: "issue-1", ident: "TST-1", repo: $repo, worktree: $wt, branch: $branch,
      name: $name, session: "session-1", phase: $phase, started: $started, since: $started}' \
    >"$c/state/night-shift/TST-1.json"
  jq -n --arg wt "$WT" --arg name "$NAME" \
    '[{id: "job-1", sessionId: "session-1", name: $name, cwd: $wt, state: "done"}]' >"$c/roster.json"
}

# --- Checks --------------------------------------------------------------------

# expect <what> <command...>: records <what> as failed unless the command
# succeeds. A case fails when any of its expectations did.
expect() {
  local what=$1
  shift
  if ! "$@"; then
    echo "    expected: $what"
    echo x >>"$c/failed"
  fi
}
not() { ! "$@"; }
is() { [[ $1 == "$2" ]]; }
has() { [[ $1 == *"$2"* ]]; }
lacks() { [[ $1 != *"$2"* ]]; }
none() { [[ $(requests "$1") == 0 ]]; }
one() { [[ $(requests "$1") == 1 ]]; }
branch_exists() { g -C "$c/projects/demo" show-ref --verify --quiet "refs/heads/$1"; }

# Nothing removed: the worktree, its branch and its session are all still
# there, and the issue says why.
kept() {
  expect "the worktree kept" test -d "$WT"
  expect "the branch kept" branch_exists "$BRANCH"
  expect "no claude rm" none '.tool == "claude" and .args[0] == "rm"'
  expect "a comment saying it was kept, $1" has "$(comments issue-1)" "Kept its worktree \`$WT\`, the branch and the agent's session, since $1"
  expect "moved to Done anyway" is "$(state issue-1)" Done
  expect "the issue forgotten" test ! -e "$c/state/night-shift/TST-1.json"
}

# Refused by start_one: in Needs you, with nothing made and no agent started.
refused() {
  ns run
  expect "exit 0" is "$status" 0
  expect "moved to Needs you" is "$(state issue-1)" "Needs you"
  expect "a comment: $1" has "$(comments issue-1)" "$1"
  expect "no worktree" test ! -e "$c/projects/demo/.claude/worktrees"
  expect "no branch" not branch_exists "$BRANCH"
  expect "no claude --bg" none '.tool == "claude" and (.args | index("--bg"))'
  expect "no state file" test ! -e "$c/state/night-shift/TST-1.json"
  expect "a push saying why" one ".tool == \"ntfy\" and .body == \"TST-1: $2\""
}

# --- 1. land_one, through run ------------------------------------------------

# A handoff whose PR merged at <sha>.
merged_handoff() {
  repo demo
  g -C "$c/projects/demo" remote set-url origin https://github.com/test/demo
  agent_worktree waiting
  issue issue-1 '.state = {name: "Handoff ready", type: "started"}'
  printf '200\n%s\n' "$(jq -nc --arg sha "${1:-$(g -C "$WT" rev-parse HEAD)}" \
    '[{number: 11, html_url: "https://github.com/test/demo/pull/11", merged_at: null, head: {sha: "0000"}},
      {number: 12, html_url: "https://github.com/test/demo/pull/12", merged_at: "2026-10-12T08:00:00Z", head: {sha: $sha}}]')" \
    >"$c/github"
}

case_land_clean() {
  merged_handoff
  ns run
  expect "exit 0" is "$status" 0
  expect "asked GitHub for the branch's PRs" one ".tool == \"github\" and (.url | endswith(\"/repos/test/demo/pulls?state=closed&head=test:$BRANCH\"))"
  expect "the worktree removed" test ! -e "$WT"
  expect "the branch deleted" not branch_exists "$BRANCH"
  expect "the branch's config section gone" not g -C "$c/projects/demo" config --get-regexp "^branch\\.$BRANCH\\."
  expect "the session removed" one '.tool == "claude" and .args == ["rm", "job-1"]'
  expect "moved to Done, the first completed state" is "$(state issue-1)" Done
  expect "a comment listing what went" has "$(comments issue-1)" "Merged in [#12](https://github.com/test/demo/pull/12). Removed its worktree, the agent's session and the branch \`$BRANCH\`."
  expect "the issue forgotten" test ! -e "$c/state/night-shift/TST-1.json"
  expect "no push" none '.tool == "ntfy"'
}

case_land_moved_tip() {
  merged_handoff
  local merged
  merged=$(g -C "$WT" rev-parse HEAD)
  echo more >>"$WT/widget.txt"
  g -C "$WT" commit -q -am "after the merge"
  ns run
  expect "exit 0" is "$status" 0
  kept "\`$BRANCH\` is at $(g -C "$WT" rev-parse --short=12 HEAD), and the PR merged ${merged:0:12}."
}

case_land_dirty() {
  merged_handoff
  echo "not committed" >"$WT/notes.txt"
  ns run
  expect "exit 0" is "$status" 0
  kept "it has changes not committed:"
  expect "the change itself kept" test -f "$WT/notes.txt"
  expect "the comment names the file" has "$(comments issue-1)" "?? notes.txt"
}

case_land_busy() {
  merged_handoff
  jq --arg wt "$WT" '. + [{id: "job-2", sessionId: "session-2", name: "a copy", cwd: $wt, state: "running"}]' \
    "$c/roster.json" >"$c/roster.tmp"
  mv "$c/roster.tmp" "$c/roster.json"
  ns run
  expect "exit 0" is "$status" 0
  kept "a session there is still at work: job-2 is running."
}

# --- 2. start_one's refusals, through run ---------------------------------------

case_start_not_creator() {
  repo demo
  issue issue-1 '.creator.id = "user-other"'
  refused "Not started: only issues you created are taken" "Not yours"
}

case_start_not_queuer() {
  repo demo
  issue issue-1 '.history.nodes += [{createdAt: "2026-10-01T10:00:00.000Z", actorId: "user-sync", toState: {name: "Queued"}}]
    | .history.nodes |= reverse'
  refused "Not started: only issues you move to Queued yourself are taken." "Not queued by you"
}

# An automation's move: recorded, with no actor. Nick created the issue, but
# the move is not his.
case_start_no_actor() {
  repo demo
  issue issue-1 '.history.nodes[1].actorId = null'
  refused "Not started: Linear recorded no person moving it to Queued" "Not queued by you"
}

case_start_long_history() {
  repo demo
  issue issue-1 '.history.pageInfo.hasNextPage = true'
  refused "Not started: its history is too long to tell who queued it." "Not started"
}

case_start_no_repo_label() {
  repo demo
  issue issue-1 '.labels.nodes |= map(select(.parent.name != "repo"))'
  refused "Not started: give it a \`repo\` label naming a repository in $c/projects with an \`origin\`." "No repo"
}

# --- 3. start_one's happy path, through run -------------------------------------

case_start() {
  repo demo
  issue issue-1
  local r=$c/projects/demo wt f bg
  wt=$r/.claude/worktrees/$NAME
  f=$c/state/night-shift/TST-1.json
  ns run
  expect "exit 0" is "$status" 0
  expect "a worktree at $wt" test -d "$wt"
  expect "on $BRANCH" is "$(g -C "$wt" symbolic-ref --short HEAD 2>&1)" "$BRANCH"
  expect "made from origin/main" is "$(g -C "$wt" rev-parse HEAD)" "$(g -C "$r" rev-parse origin/main)"
  expect "with no upstream" not g -C "$r" config --get "branch.$BRANCH.remote"
  expect "TST-1.issue.md written" has "$(cat "$r/.git/night-shift/TST-1.issue.md" 2>&1)" "Make the widget work again."
  expect "claude --bg called once" one '.tool == "claude" and .args[0] == "--bg"'
  bg=$(jq -sc 'map(select(.tool == "claude" and .args[0] == "--bg")) | first' "$c/log.jsonl")
  expect "in the worktree" is "$(jq -r .cwd <<<"$bg")" "$wt"
  expect "named $NAME, in auto mode" is "$(jq -c '.args[1:5]' <<<"$bg")" "[\"-n\",\"$NAME\",\"--permission-mode\",\"auto\"]"
  expect "given the task" has "$(jq -r '.args[5]' <<<"$bg")" "# TST-1: Fix the widget"
  expect "through systemd-run, outside the unit" one '.tool == "systemd-run" and (.args | index("--bg"))'
  expect "moved to Running" is "$(state issue-1)" Running
  expect "a state file, phase running" is "$(jq -r .phase "$f" 2>&1)" running
  expect "with the session from the roster" is "$(jq -r .session "$f" 2>&1)" session-1
  expect "forge kept awake, on AC" one '.tool == "systemctl" and .args == ["--user", "start", "night-shift-awake.service"]'
  expect "and not let sleep" none '.tool == "systemctl" and .args[1] == "stop"'
}

# Created straight into Queued: no move recorded, so the creator queued it.
case_start_created_queued() {
  repo demo
  issue issue-1 '.history.nodes = []'
  ns run
  expect "exit 0" is "$status" 0
  expect "claude --bg called once" one '.tool == "claude" and .args[0] == "--bg"'
  expect "moved to Running" is "$(state issue-1)" Running
}

case_start_battery() {
  repo demo
  issue issue-1
  echo 0 >"$c/power/AC/online"
  ns run
  expect "exit 0" is "$status" 0
  expect "started anyway" is "$(state issue-1)" Running
  expect "forge let sleep, on battery" one '.tool == "systemctl" and .args == ["--user", "stop", "night-shift-awake.service"]'
  expect "and not kept awake" none '.tool == "systemctl" and .args[1] == "start"'
}

# --- 4. finish_one ---------------------------------------------------------------

# A running agent on TST-1, started <started>, that wrote <result>, if given.
# The roster says its session is at work.
running_agent() {
  repo demo
  agent_worktree running "${1:-$(date -u +%FT%TZ)}"
  jq 'map(.state = "running")' "$c/roster.json" >"$c/roster.tmp"
  mv "$c/roster.tmp" "$c/roster.json"
  issue issue-1 '.state = {name: "Running", type: "started"}'
  RESULT=$c/projects/demo/.git/night-shift/TST-1.md
  if [[ -n ${2-} ]]; then
    mkdir -p "$(dirname "$RESULT")"
    printf '%s\n' "$2" >"$RESULT"
  fi
}

archived() {
  local a=("$RESULT".*)
  [[ ! -e $RESULT && ${#a[@]} == 1 ]]
}

case_finish_handoff() {
  running_agent "" $'handoff\nFixed the widget; preflight passes.'
  ns run
  expect "exit 0" is "$status" 0
  expect "moved to Handoff ready" is "$(state issue-1)" "Handoff ready"
  expect "a comment with the result" has "$(comments issue-1)" "Handoff ready on \`$BRANCH\`."$'\n\n'"Fixed the widget; preflight passes."
  expect "the comment says how to publish" has "$(comments issue-1)" "To publish: \`cd $WT && pr-handoff\`."
  expect "the result archived" archived
  expect "phase waiting" is "$(jq -r .phase "$c/state/night-shift/TST-1.json")" waiting
  expect "a push" one '.tool == "ntfy" and .body == "TST-1: Handoff ready" and .title == "Night shift"'
  expect "no preflight, with no rules in the repo" none '.tool == "bwrap"'
  expect "forge let sleep, with nothing running" one '.tool == "systemctl" and .args == ["--user", "stop", "night-shift-awake.service"]'
}

case_finish_blocked() {
  running_agent "" $'blocked\n1. Which widget?'
  ns run
  expect "exit 0" is "$status" 0
  expect "moved to Needs you" is "$(state issue-1)" "Needs you"
  expect "a comment with the questions" has "$(comments issue-1)" $'The agent stopped and needs you.\n\n1. Which widget?'
  expect "the result archived" archived
  expect "phase waiting" is "$(jq -r .phase "$c/state/night-shift/TST-1.json")" waiting
  expect "a push" one '.tool == "ntfy" and .body == "TST-1: Needs you"'
}

# set_state <jq filter> [jq args...]: TST-1's state file, changed.
set_state() {
  local f=$c/state/night-shift/TST-1.json filter=$1
  shift
  jq "$@" "$filter" "$f" >"$f.tmp"
  mv "$f.tmp" "$f"
}

case_finish_quiet() {
  running_agent "$(date -u -d '5 hours ago' +%FT%TZ)"
  # A minute short of 4 hours of work as of the last run, 5 minutes ago.
  set_state '.worked = 4 * 3600 - 60 | .ticked = $t' --arg t "$(date -u -d '5 minutes ago' +%FT%TZ)"
  ns run
  expect "exit 0" is "$status" 0
  expect "moved to Needs you" is "$(state issue-1)" "Needs you"
  expect "a comment saying so" has "$(comments issue-1)" "No result after 4 hours of work."
  expect "a push" one '.tool == "ntfy" and .body == "TST-1: Went quiet"'
  expect "phase waiting" is "$(jq -r .phase "$c/state/night-shift/TST-1.json")" waiting
}

case_finish_working() {
  running_agent "$(date -u -d '3 hours ago' +%FT%TZ)"
  ns run
  expect "exit 0" is "$status" 0
  expect "left in Running" is "$(state issue-1)" Running
  expect "not asked about in Linear" none '.tool == "linear" and .op == "issue"'
  expect "phase still running" is "$(jq -r .phase "$c/state/night-shift/TST-1.json")" running
}

# Started 17 hours ago, at work, and no run since: forge was asleep, and the
# gap counts as one tick, not as 17 hours of silence.
case_finish_asleep() {
  running_agent "$(date -u -d '17 hours ago' +%FT%TZ)"
  ns run
  expect "exit 0" is "$status" 0
  expect "left in Running" is "$(state issue-1)" Running
  expect "not asked about in Linear" none '.tool == "linear" and .op == "issue"'
  expect "20 minutes of work counted" is "$(jq -r .worked "$c/state/night-shift/TST-1.json")" 1200
  expect "forge kept awake" one '.tool == "systemctl" and .args[1] == "start"'
}

# The session ended without a result: left alone on the first look, flagged
# on one 5 minutes or more later.
case_finish_ended() {
  running_agent
  jq 'map(.state = "done")' "$c/roster.json" >"$c/roster.tmp"
  mv "$c/roster.tmp" "$c/roster.json"
  ns run
  expect "exit 0" is "$status" 0
  expect "left in Running at first" is "$(state issue-1)" Running
  expect "the end noted" test -n "$(jq -r '.ended // empty' "$c/state/night-shift/TST-1.json")"
  set_state '.ended = $t' --arg t "$(date -u -d '10 minutes ago' +%FT%TZ)"
  ns run
  expect "exit 0, again" is "$status" 0
  expect "then moved to Needs you" is "$(state issue-1)" "Needs you"
  expect "a comment saying so" has "$(comments issue-1)" "The agent's session ended (done) without writing a result. \`claude attach $NAME\`"
  expect "a push" one '.tool == "ntfy" and .body == "TST-1: Went quiet"'
}

# Waiting on a prompt: the same two looks, and says so.
case_finish_prompt() {
  running_agent
  jq 'map(.state = "blocked")' "$c/roster.json" >"$c/roster.tmp"
  mv "$c/roster.tmp" "$c/roster.json"
  set_state '.ended = $t' --arg t "$(date -u -d '10 minutes ago' +%FT%TZ)"
  ns run
  expect "exit 0" is "$status" 0
  expect "moved to Needs you" is "$(state issue-1)" "Needs you"
  expect "a comment saying so" has "$(comments issue-1)" "The agent is waiting on a prompt, with no result."
}

# Seen ended, then missing from the roster: the end seen stands.
case_finish_roster_gap() {
  running_agent
  echo '[]' >"$c/roster.json"
  set_state '.ended = $t | .ended_as = "done"' --arg t "$(date -u -d '10 minutes ago' +%FT%TZ)"
  ns run
  expect "exit 0" is "$status" 0
  expect "moved to Needs you" is "$(state issue-1)" "Needs you"
  expect "a comment naming the state seen" has "$(comments issue-1)" "The agent's session ended (done) without writing a result."
}

# A result after the issue was flagged, as when Nick answers the agent with
# claude attach: taken like any other.
case_finish_late() {
  running_agent "" $'handoff\nFixed the widget after all.'
  set_state '.phase = "waiting"'
  issue issue-1 '.state = {name: "Needs you", type: "started"}'
  ns run
  expect "exit 0" is "$status" 0
  expect "moved to Handoff ready" is "$(state issue-1)" "Handoff ready"
  expect "a comment with the result" has "$(comments issue-1)" "Fixed the widget after all."
  expect "the result archived" archived
  expect "phase waiting" is "$(jq -r .phase "$c/state/night-shift/TST-1.json")" waiting
}

# A waiting issue with no result is left alone, though its session has ended
# as one that went quiet does.
case_finish_waiting() {
  running_agent
  jq 'map(.state = "done")' "$c/roster.json" >"$c/roster.tmp"
  mv "$c/roster.tmp" "$c/roster.json"
  set_state '.phase = "waiting" | .ended = $t' --arg t "$(date -u -d '10 minutes ago' +%FT%TZ)"
  issue issue-1 '.state = {name: "Needs you", type: "started"}'
  ns run
  expect "exit 0" is "$status" 0
  expect "left in Needs you" is "$(state issue-1)" "Needs you"
  expect "not asked about in Linear" none '.tool == "linear" and .op == "issue"'
}

# Linear unreachable, forge taken off AC with an agent running: the run
# fails, and still lets forge sleep.
case_awake_offline() {
  running_agent
  touch "$c/linear-down"
  echo 0 >"$c/power/AC/online"
  ns run
  expect "the run fails" is "$status" 1
  expect "forge let sleep anyway" one '.tool == "systemctl" and .args == ["--user", "stop", "night-shift-awake.service"]'
}

# _finish alone, since run would go on to resume it (the next case).
case_finish_requeued() {
  running_agent "" $'handoff\nFixed the widget.'
  issue issue-1
  ns _finish user-nick "$c/state/night-shift/TST-1.json"
  expect "exit 0" is "$status" 0
  expect "left in Queued" is "$(state issue-1)" Queued
  expect "not moved" none '.tool == "linear" and .op == "issueUpdate"'
  expect "a comment with the result" has "$(comments issue-1)" "Fixed the widget."
  expect "no push" none '.tool == "ntfy"'
  expect "the result archived" archived
  expect "phase waiting" is "$(jq -r .phase "$c/state/night-shift/TST-1.json")" waiting
}

case_finish_requeued_resumes() {
  running_agent "" $'handoff\nFixed the widget.'
  issue issue-1 '.comments.nodes = [{body: "Use the blue one.", createdAt: "2030-01-01T00:00:00.000Z", user: {id: "user-nick"}}]'
  ns run
  expect "exit 0" is "$status" 0
  expect "the finished session stopped first" one '.tool == "claude" and .args == ["stop", "job-1"]'
  expect "resumed once, with no new flags" one '.tool == "claude" and .args[0:3] == ["--bg", "--resume", "session-1"] and (.args | length) == 4'
  expect "given Nick's comment" one '.tool == "claude" and .args[0] == "--bg" and (.args[3] | contains("Use the blue one."))'
  expect "moved to Running" is "$(state issue-1)" Running
  expect "phase running" is "$(jq -r .phase "$c/state/night-shift/TST-1.json")" running
}

# The roster still calls the session running for two looks after the stop:
# the resume waits for it to say stopped.
case_finish_requeued_slow_stop() {
  running_agent "" $'handoff\nFixed the widget.'
  issue issue-1 '.comments.nodes = [{body: "Use the blue one.", createdAt: "2030-01-01T00:00:00.000Z", user: {id: "user-nick"}}]'
  touch "$c/stop-slow"
  ns run
  expect "exit 0" is "$status" 0
  expect "resumed once" one '.tool == "claude" and .args[0:2] == ["--bg", "--resume"]'
  expect "three looks between the stop and the resume" is "$(jq -s '
    map(select(.tool == "claude")) | (map(.args[0]) | index("stop")) as $s
    | (map(.args[1]) | index("--resume")) as $r | .[$s:$r] | map(select(.args[0] == "agents")) | length' "$c/log.jsonl")" 3
}

# --- 5. night-shift file's refusals -----------------------------------------------

# Each beside a draft that is fine, which must not be filed either.
drafts() {
  repo demo
  mkdir -p "$c/projects/demo/.git/linear-handoff"
  cp "$here/drafts/good.md" "$c/projects/demo/.git/linear-handoff/"
}

refused_drafts() {
  ns file
  expect "a failure" is "$status" 1
  expect "nothing filed" has "$(<"$c/out")" "nothing filed"
  expect "the reason: $2" has "$(<"$c/out")" "$1: $2"
  expect "no issueCreate" none '.op == "issueCreate"'
  expect "the good draft kept" test -f "$c/projects/demo/.git/linear-handoff/good.md"
  expect "the bad draft kept" test -f "$1"
}

case_file_unknown_key() {
  drafts
  cp "$here/drafts/unknown-key.md" "$c/projects/demo/.git/linear-handoff/"
  refused_drafts "$c/projects/demo/.git/linear-handoff/unknown-key.md" "unknown key 'assignee'"
}

case_file_control() {
  drafts
  printf -- '---\ntitle: forge: a control character\n---\n\nA bell \a in the text.\n' \
    >"$c/projects/demo/.git/linear-handoff/control.md"
  refused_drafts "$c/projects/demo/.git/linear-handoff/control.md" "contains control or invisible characters"
}

case_file_no_title() {
  drafts
  cp "$here/drafts/no-title.md" "$c/projects/demo/.git/linear-handoff/"
  refused_drafts "$c/projects/demo/.git/linear-handoff/no-title.md" "no title"
}

# The happy path needs a terminal to answer on, and util-linux's script to
# give it one; elsewhere, macOS's own script say, it is skipped.
case_file_interactive() {
  if [[ $(script --version 2>/dev/null) != *util-linux* ]]; then
    echo "no util-linux script to drive a terminal" >"$c/skipped"
    return 0
  fi
  drafts
  sed 's/^title: .*/title: forge: a later change/' "$here/drafts/good.md" \
    >"$c/projects/demo/.git/linear-handoff/later.md"
  tty=$'y\nn\n'
  ns file
  expect "exit 0" is "$status" 0
  expect "shows what it will file" has "$(<"$c/out")" "TST · demo · high · Night shift · into Backlog"
  expect "one issueCreate" one '.op == "issueCreate"'
  expect "filed as the draft says, into the backlog" is "$(jq -sc 'map(select(.op == "issueCreate")) | first | .variables.i' "$c/log.jsonl")" \
    "$(jq -nc '{teamId: "team-1", title: "forge: make the widget faster", priority: 2,
      description: "The widget takes a second to draw. Make it take less.\n\n_Filed from a draft with `night-shift file`._",
      labelIds: ["label-demo"], stateId: "state-backlog", projectId: "project-1"}')"
  expect "the filed draft gone" test ! -e "$c/projects/demo/.git/linear-handoff/good.md" -a ! -e "$c/projects/demo/.git/linear-handoff/good.filing"
  expect "the declined draft kept" test -f "$c/projects/demo/.git/linear-handoff/later.md"
  expect "says what it filed" has "$(<"$c/out")" "filed TST-99"
  expect "filed 1 of 2" has "$(<"$c/out")" "filed 1 of 2"
  expect "then writes the backlog" test -f "$c/state/night-shift/backlog.md"
}

# --- 6. _after ---------------------------------------------------------------------

pushes() { requests '.tool == "ntfy" and .title == "Night shift is failing"'; }

case_after() {
  local n
  for n in 1 2 3 4; do
    ns SERVICE_RESULT=exit-code EXIT_STATUS=1 _after
    expect "run $n: exit 0" is "$status" 0
    expect "run $n: count $n" is "$(cat "$c/state/night-shift/failed-runs")" "$n"
    expect "run $n: $((n >= 3 ? 1 : 0)) push(es) so far" is "$(pushes)" "$((n >= 3 ? 1 : 0))"
  done
  expect "the push says why" has "$(jq -rs 'map(select(.tool == "ntfy")) | first | .body' "$c/log.jsonl")" "The last 3 runs failed, the last with exit-code 1"
  ns SERVICE_RESULT=success _after
  expect "a success resets the count" test ! -e "$c/state/night-shift/failed-runs"
  expect "and the push" test ! -e "$c/state/night-shift/failed-runs.pushed"
  for n in 1 2 3; do
    ns SERVICE_RESULT=timeout _after
  done
  expect "three more failures push again" is "$(pushes)" 2
}

case_after_push_failed() {
  local n
  touch "$c/ntfy-fail"
  for n in 1 2 3; do
    ns SERVICE_RESULT=exit-code _after
  done
  expect "the third tried to push" is "$(pushes)" 1
  expect "not marked pushed" test ! -e "$c/state/night-shift/failed-runs.pushed"
  rm "$c/ntfy-fail"
  ns SERVICE_RESULT=exit-code _after
  expect "the fourth tries again" is "$(pushes)" 2
  expect "and is marked pushed" test -e "$c/state/night-shift/failed-runs.pushed"
}

# --- 7. tidy ---------------------------------------------------------------------

case_tidy_refused() {
  local n
  repo demo
  g -C "$c/projects/demo" remote set-url origin https://github.com/test/demo
  for n in 1 2; do
    issue "issue-$n" ".identifier = \"TST-$n\" | .state = {name: \"Handoff ready\", type: \"started\"}"
    jq -n --arg n "$n" --arg repo "$c/projects/demo" \
      '{id: "issue-\($n)", ident: "TST-\($n)", repo: $repo, worktree: "\($repo)/.claude/worktrees/tst-\($n)",
        branch: "worktree-tst-\($n)", name: "tst-\($n)", session: "", phase: "waiting",
        started: "2026-10-12T00:00:00Z", since: "2026-10-12T00:00:00Z"}' >"$c/state/night-shift/TST-$n.json"
  done
  printf '403\n{"message": "API rate limit exceeded"}\n' >"$c/github"
  ns run
  expect "exit 0" is "$status" 0
  expect "GitHub asked once" one '.tool == "github"'
  expect "says it was refused" has "$(<"$c/out")" "GitHub refused"
  expect "both issues kept" test -e "$c/state/night-shift/TST-1.json" -a -e "$c/state/night-shift/TST-2.json"
  expect "neither moved" none '.op == "issueUpdate"'
}

# --- 8. Work mode ----------------------------------------------------------------

# nsw [VAR=value...] <command> [args]: the dispatcher in work mode on a Mac,
# with the case's config, the settings fixture standing in for Nix's, and the
# key from a command, as the keychain gives it.
nsw() {
  ns NIGHT_SHIFT_MODE=work NIGHT_SHIFT_PLATFORM=darwin NIGHT_SHIFT_CONFIG="$c/config.json" \
    NIGHT_SHIFT_SETTINGS="$here/fixtures/work-settings.json" NIGHT_SHIFT_KEY_CMD="cat $c/key" \
    NIGHT_SHIFT_LOG="$c/night-shift.log" "$@"
}

# work <jq filter>: repo demo, an issue from fixtures/work-issue.json, and a
# config for team TST. Its setup logs itself, so a case can see it ran, and
# when.
WBRANCH=feat/TST-1/fix-the-widget
work() {
  repo demo
  jq --arg id issue-1 ".id = \$id | ${1:-.}" "$here/fixtures/work-issue.json" >"$c/linear/issues/issue-1.json"
  jq -n --arg dir "$c/projects/demo" --arg log "$c/log.jsonl" '{label: "agent", startedState: "In Progress",
    repos: {TST: {dir: $dir, branch: "feat/{ID}/{slug}", checks: "make check",
      bootstrap: ["touch bootstrapped", "echo '\''{\"tool\": \"bootstrap\"}'\'' >>\($log)"],
      sandbox: {allowedDomains: ["pypi.org"], allowLocalBinding: true, env: {SCRATCH_DIR: "/x", GIT_TERMINAL_PROMPT: "1"}}}}}' >"$c/config.json"
}

# A worktree work mode would have made for TST-1, and the state file of an
# issue that has reached <phase>.
work_agent() {
  local r=$c/projects/demo phase=$1 started=${2:-$(date -u +%FT%TZ)}
  WT=$r/.claude/worktrees/$NAME
  g -C "$r" worktree add -q --no-track -b "$WBRANCH" "$WT" origin/main
  echo widget >"$WT/widget.txt"
  g -C "$WT" add widget.txt
  g -C "$WT" commit -q -m "fix the widget"
  jq -n --arg repo "$r" --arg wt "$WT" --arg branch "$WBRANCH" --arg name "$NAME" \
    --arg phase "$phase" --arg started "$started" \
    '{id: "issue-1", ident: "TST-1", repo: $repo, worktree: $wt, branch: $branch, name: $name,
      session: "session-1", phase: $phase, started: $started, since: $started,
      labelled: "2026-10-02T09:00:00.000Z"}' >"$c/state/night-shift/TST-1.json"
  echo '{}' >"$c/state/night-shift/TST-1.settings"
  jq -n --arg wt "$WT" --arg name "$NAME" \
    '[{id: "job-1", sessionId: "session-1", name: $name, cwd: $wt, state: "done"}]' >"$c/roster.json"
}

no_linear_writes() {
  expect "no issueUpdate" none '.op == "issueUpdate"'
  expect "no comment" none '.op == "commentCreate"'
}

notified() { one ".tool == \"notify\" and .title == \"Night shift\" and .body == \"TST-1: $1\""; }

case_work_start() {
  work
  local r=$c/projects/demo wt f bg settings
  wt=$r/.claude/worktrees/$NAME
  f=$c/state/night-shift/TST-1.json
  settings=$c/state/night-shift/TST-1.settings
  mkdir -p "$c/home/.claude" "$r/.claude"
  echo '{"enabledPlugins": {"core@nnorx": true, "mine@x": true}}' >"$c/home/.claude/settings.json"
  echo '{"enabledPlugins": {"lsp@x": true}}' >"$r/.claude/settings.local.json"
  nsw run
  expect "exit 0" is "$status" 0
  expect "a worktree at $wt" test -d "$wt"
  expect "on the branch from the template, $WBRANCH" is "$(g -C "$wt" symbolic-ref --short HEAD 2>&1)" "$WBRANCH"
  expect "set up by the config's commands" test -f "$wt/bootstrapped"
  expect "set up before claude started" is "$(jq -sr 'map(select(.tool == "bootstrap" or (.tool == "claude" and .args[0] == "--bg"))) | map(.tool) | join(",")' "$c/log.jsonl")" "bootstrap,claude"
  bg=$(jq -sc 'map(select(.tool == "claude" and .args[0] == "--bg")) | first' "$c/log.jsonl")
  expect "claude --bg in the worktree" is "$(jq -r .cwd <<<"$bg")" "$wt"
  expect "with its settings, no MCP servers, in auto mode" is "$(jq -c '.args[1:8]' <<<"$bg")" \
    "$(jq -nc --arg n "$NAME" --arg s "$settings" '["-n", $n, "--settings", $s, "--strict-mcp-config", "--permission-mode", "auto"]')"
  expect "given the task and the checks" has "$(jq -r '.args[8]' <<<"$bg")" "Checks: make check."
  expect "started directly, not through systemd-run" none '.tool == "systemd-run"'
  expect "the settings add the repo's host" is "$(jq -c .sandbox.network.allowedDomains "$settings" 2>&1)" '["github.com","pypi.org"]'
  expect "and binding to localhost" is "$(jq -r .sandbox.network.allowLocalBinding "$settings" 2>&1)" true
  expect "and its environment" is "$(jq -r .env.SCRATCH_DIR "$settings" 2>&1)" /x
  expect "but not over the base's" is "$(jq -r .env.GIT_TERMINAL_PROMPT "$settings" 2>&1)" 0
  expect "and keep the base's denials" is "$(jq -c .sandbox.filesystem.denyRead "$settings" 2>&1)" '["~/.ssh","~/Library/Keychains"]'
  expect "hooks off" is "$(jq -r .disableAllHooks "$settings" 2>&1)" true
  expect "every plugin a scope enables off, but the base's" is "$(jq -c .enabledPlugins "$settings" 2>&1)" \
    '{"core@nnorx":true,"lsp@x":false,"mine@x":false}'
  expect "the worktree's own settings sandbox it too" is "$(jq -c '[.sandbox.enabled, .permissions.deny, .disableAllHooks, .enabledPlugins."lsp@x"]' "$wt/.claude/settings.local.json" 2>&1)" '[true,["Bash(git push:*)"],true,false]'
  expect "moved to In Progress, once" one '.op == "issueUpdate"'
  expect "In Progress in Linear" is "$(state issue-1)" "In Progress"
  expect "no comment" none '.op == "commentCreate"'
  expect "a state file, phase running" is "$(jq -r .phase "$f" 2>&1)" running
  expect "which records what setup left" is "$(jq -c '.setup | index("?? bootstrapped") != null' "$f" 2>&1)" true
  expect "no notification" none '.tool == "notify"'
}

# Refused by work_start_one: nothing made, no agent, nothing written to
# Linear, and said once, in a notification and the report.
work_refused() {
  nsw run
  expect "exit 0" is "$status" 0
  expect "no worktree" test ! -e "$c/projects/demo/.claude/worktrees/$NAME"
  expect "no branch" not branch_exists "$WBRANCH"
  expect "no claude --bg" none '.tool == "claude" and (.args | index("--bg"))'
  no_linear_writes
  expect "phase refused" is "$(jq -r .phase "$c/state/night-shift/TST-1.json" 2>&1)" refused
  expect "the report says why: $1" has "$(cat "$c/state/night-shift/TST-1.report.md" 2>&1)" "$1"
  expect "a notification" notified "Not started"
  nsw run
  expect "said once, not every run" notified "Not started"
  expect "not asked about again, unchanged" one '.tool == "linear" and .op == "issue"'
}

case_work_start_not_labeler() {
  work '.history.nodes[1].actorId = "user-teammate"'
  work_refused "the label was last added by someone else or by an integration"
}

case_work_start_bot() {
  work '.history.nodes[1].botActor = {id: "bot-mcp"}'
  work_refused "the label was last added by someone else or by an integration"
}

# Linear's filter leaves it out of the queue, so a run passes it over in
# silence; work_start_one refuses it all the same when handed it.
case_work_start_not_assignee() {
  work '.assignee.id = "user-teammate"'
  nsw run
  expect "exit 0" is "$status" 0
  expect "not in the queue" none '.tool == "linear" and .op == "issue"'
  expect "no notification" none '.tool == "notify"'
  nsw _start user-nick issue-1
  expect "refused when handed it" has "$(cat "$c/state/night-shift/TST-1.report.md" 2>&1)" "it is not assigned to you"
  expect "no claude --bg" none '.tool == "claude" and (.args | index("--bg"))'
  no_linear_writes
}

case_work_start_edited() {
  work '.history.nodes += [{createdAt: "2026-10-03T09:00:00.000Z", actorId: "user-teammate", botActor: null,
    addedLabelIds: null, updatedDescription: true, fromTitle: null}]'
  work_refused "someone else changed its title or description after you added the label"
}

case_work_start_relabelled() {
  work '.history.nodes[1].actorId = "user-teammate"'
  nsw run
  expect "refused first" is "$(jq -r .phase "$c/state/night-shift/TST-1.json" 2>&1)" refused
  jq '.updatedAt = "2026-10-04T09:00:00.000Z"
    | .history.nodes += [{createdAt: "2026-10-04T09:00:00.000Z", actorId: "user-nick", botActor: null,
    addedLabelIds: ["label-agent"], updatedDescription: null, fromTitle: null}]' \
    "$c/linear/issues/issue-1.json" >"$c/tmp/issue.json"
  mv "$c/tmp/issue.json" "$c/linear/issues/issue-1.json"
  nsw run
  expect "exit 0" is "$status" 0
  expect "started once Nick added the label again" one '.tool == "claude" and .args[0] == "--bg"'
  expect "phase running" is "$(jq -r .phase "$c/state/night-shift/TST-1.json" 2>&1)" running
}

case_work_bootstrap_fails() {
  work
  jq '.repos.TST.bootstrap = ["exit 3"]' "$c/config.json" >"$c/tmp/config.json"
  mv "$c/tmp/config.json" "$c/config.json"
  work_refused "setting up the worktree failed, and it is removed."
  expect "the setup log kept" has "$(cat "$c/state/night-shift/TST-1.bootstrap.log" 2>&1)" '$ exit 3'
}

case_work_overrides() {
  work
  mkdir -p "$c/projects/demo/.claude"
  echo '{"sandbox": {"excludedCommands": ["docker *"]}}' >"$c/projects/demo/.claude/settings.local.json"
  work_refused "these settings would change the agent's sandbox or run a command outside it: $c/projects/demo/.claude/settings.local.json"
}

# A helper command Claude runs itself, outside the sandbox, from the branch's
# own settings: refused. Nick's own, in his user settings, is not.
case_work_helper() {
  work
  local seed=$c/tmp/seed-helper
  g clone -q "$c/remote/demo.git" "$seed"
  mkdir -p "$seed/.claude"
  echo '{"apiKeyHelper": "./get-key.sh"}' >"$seed/.claude/settings.json"
  g -C "$seed" add .claude/settings.json
  g -C "$seed" commit -q -m "a helper"
  g -C "$seed" push -q origin HEAD:main
  work_refused "these settings would change the agent's sandbox or run a command outside it: $c/projects/demo/.claude/worktrees/$NAME/.claude/settings.json"
}

case_work_helper_user() {
  work
  mkdir -p "$c/home/.claude"
  echo '{"apiKeyHelper": "/usr/local/bin/get-key"}' >"$c/home/.claude/settings.json"
  nsw run
  expect "exit 0" is "$status" 0
  expect "started" is "$(jq -r .phase "$c/state/night-shift/TST-1.json" 2>&1)" running
}

# A tracked file setup changed is not recorded as setup's: the agent may
# change it too, and land_one would then remove the worktree with its work.
case_work_setup_tracked() {
  work
  jq '.repos.TST.bootstrap = ["touch made", "echo more >>README.md"]' "$c/config.json" >"$c/tmp/config.json"
  mv "$c/tmp/config.json" "$c/config.json"
  nsw run
  expect "exit 0" is "$status" 0
  expect "the untracked file recorded, not the changed one" is \
    "$(jq -c '[index("?? made") != null, any(.[]; endswith("README.md"))]' <<<"$(jq -c .setup "$c/state/night-shift/TST-1.json")" 2>&1)" \
    '[true,false]'
}

case_work_finish_handoff() {
  work '.state = {name: "In Progress", type: "started"}'
  work_agent running
  mkdir -p "$c/projects/demo/.git/night-shift"
  printf 'handoff\nFixed the widget; the checks pass.\n' >"$c/projects/demo/.git/night-shift/TST-1.md"
  nsw run
  expect "exit 0" is "$status" 0
  no_linear_writes
  expect "a notification" notified "Handoff ready"
  expect "the text never reaches AppleScript's script" none '.tool == "notify" and (.script | join(" ") | contains("TST-1"))'
  expect "the report has the result" has "$(cat "$c/state/night-shift/TST-1.report.md" 2>&1)" "Fixed the widget; the checks pass."
  expect "and how to publish" has "$(cat "$c/state/night-shift/TST-1.report.md" 2>&1)" "To publish: \`cd $WT && pr-handoff\`."
  expect "no preflight" none '.tool == "bwrap"'
  expect "phase waiting" is "$(jq -r .phase "$c/state/night-shift/TST-1.json")" waiting
  expect "status shows the report" has "$(nsw status && cat "$c/out")" "# TST-1: Handoff ready"
}

case_work_finish_blocked() {
  work '.state = {name: "In Progress", type: "started"}'
  work_agent running
  mkdir -p "$c/projects/demo/.git/night-shift"
  printf 'blocked\n1. Which widget?\n' >"$c/projects/demo/.git/night-shift/TST-1.md"
  nsw run
  expect "exit 0" is "$status" 0
  no_linear_writes
  expect "a notification" notified "Needs you"
  expect "the report says how to answer" has "$(cat "$c/state/night-shift/TST-1.report.md" 2>&1)" "\`night-shift resume TST-1 \"<answer>\"\`"
}

case_work_resume() {
  work '.state = {name: "In Progress", type: "started"}'
  work_agent waiting
  nsw resume tst-1 "Use the blue one."
  expect "resume: exit 0" is "$status" 0
  nsw run
  expect "exit 0" is "$status" 0
  expect "the finished session stopped first" one '.tool == "claude" and .args == ["stop", "job-1"]'
  expect "resumed once, with no new flags" one '.tool == "claude" and .args[0:3] == ["--bg", "--resume", "session-1"] and (.args | length) == 4'
  expect "given the answer" one '.tool == "claude" and .args[0] == "--bg" and (.args[3] | contains("with this answer:\n\nUse the blue one."))'
  expect "the answer used up" test ! -e "$c/state/night-shift/TST-1.answer"
  expect "phase running" is "$(jq -r .phase "$c/state/night-shift/TST-1.json")" running
  expect "already In Progress, so not moved" none '.op == "issueUpdate"'
}

# resume starts launchd's run at once, when given its job.
case_work_resume_now() {
  work '.state = {name: "In Progress", type: "started"}'
  work_agent waiting
  nsw NIGHT_SHIFT_LAUNCHD_LABEL=org.example.night-shift resume TST-1 "Use the blue one."
  expect "exit 0" is "$status" 0
  expect "the answer kept for the run" test -f "$c/state/night-shift/TST-1.answer"
  expect "launchd's job started" one ".tool == \"launchctl\" and .args == [\"kickstart\", \"gui/$(id -u)/org.example.night-shift\"]"
  expect "says the run is starting" has "$(<"$c/out")" "TST-1 resumes in the run starting now"
}

# No job to start, or one launchctl cannot find: the answer waits for the
# next run, as before.
case_work_resume_no_job() {
  work '.state = {name: "In Progress", type: "started"}'
  work_agent waiting
  nsw resume TST-1 "Use the blue one."
  expect "exit 0" is "$status" 0
  expect "nothing started without a job" none '.tool == "launchctl"'
  touch "$c/launchctl-fail"
  nsw NIGHT_SHIFT_LAUNCHD_LABEL=org.example.night-shift resume TST-1 "Use the red one."
  expect "exit 0 when launchctl fails" is "$status" 0
  expect "the newer answer kept" is "$(cat "$c/state/night-shift/TST-1.answer" 2>&1)" "Use the red one."
  expect "says it waits for the next run" has "$(<"$c/out")" "TST-1 resumes on the next run"
  expect "never that a run started" lacks "$(<"$c/out")" "run starting now"
}

case_work_resume_relabelled() {
  work '.state = {name: "In Progress", type: "started"} | .updatedAt = "2030-01-01T00:00:00.000Z"
    | .history.nodes += [{createdAt: "2030-01-01T00:00:00.000Z", actorId: "user-nick", botActor: null,
      addedLabelIds: ["label-agent"], updatedDescription: null, fromTitle: null}]'
  work_agent waiting
  nsw run
  expect "exit 0" is "$status" 0
  expect "resumed, saying how" one '.tool == "claude" and .args[0:3] == ["--bg", "--resume", "session-1"] and (.args[3] | contains("by adding its label again"))'
  nsw run
  expect "once" one '.tool == "claude" and .args[0:2] == ["--bg", "--resume"]'
}

case_work_land() {
  work '.state = {name: "Done", type: "completed"}'
  work_agent waiting
  jq -nc --arg sha "$(g -C "$WT" rev-parse HEAD)" \
    '[{number: 7, url: "https://github.com/test/demo/pull/7", headRefOid: $sha}]' >"$c/gh-prs"
  g -C "$c/projects/demo" remote set-url origin git@github.com:test/demo.git
  nsw run
  expect "exit 0" is "$status" 0
  expect "asked gh for the branch's merged PRs" one ".tool == \"gh\" and .args[0:7] == [\"pr\", \"list\", \"--repo\", \"test/demo\", \"--head\", \"$WBRANCH\", \"--state\"]"
  expect "never GitHub's API" none '.tool == "github"'
  expect "the worktree removed" test ! -e "$WT"
  expect "the branch deleted" not branch_exists "$WBRANCH"
  expect "the session removed" one '.tool == "claude" and .args == ["rm", "job-1"]'
  expect "and the settings it was started with" test ! -e "$c/state/night-shift/TST-1.settings"
  no_linear_writes
  expect "the issue forgotten" test ! -e "$c/state/night-shift/TST-1.json"
  expect "the log says so" has "$(<"$c/out")" "TST-1: Merged in [#7](https://github.com/test/demo/pull/7). Removed its worktree"
}

# An agent can write the repository's shared refs, origin/HEAD among them,
# which fetch leaves alone. What the next worktree is made from comes from
# origin itself.
poison_head() {
  local r=$c/projects/demo
  g -C "$r" checkout -q -b evil
  echo "the agent's" >"$r/evil.txt"
  g -C "$r" add evil.txt
  g -C "$r" commit -q -m "evil"
  g -C "$r" checkout -q main
  g -C "$r" symbolic-ref refs/remotes/origin/HEAD refs/heads/evil
}

case_start_poisoned_head() {
  repo demo
  issue issue-1
  poison_head
  ns run
  expect "exit 0" is "$status" 0
  expect "made from origin's main" is "$(g -C "$c/projects/demo/.claude/worktrees/$NAME" rev-parse HEAD 2>&1)" \
    "$(g -C "$c/remote/demo.git" rev-parse main)"
  expect "with nothing of the agent's" test ! -e "$c/projects/demo/.claude/worktrees/$NAME/evil.txt"
}

case_work_start_poisoned_head() {
  work
  poison_head
  nsw run
  expect "exit 0" is "$status" 0
  expect "made from origin's main" is "$(g -C "$c/projects/demo/.claude/worktrees/$NAME" rev-parse HEAD 2>&1)" \
    "$(g -C "$c/remote/demo.git" rev-parse main)"
  expect "set up with nothing of the agent's" test ! -e "$c/projects/demo/.claude/worktrees/$NAME/evil.txt"
}

case_work_bg_fails() {
  work
  touch "$c/claude-fail"
  nsw run
  expect "exit 0" is "$status" 0
  expect "refused, saying why" has "$(cat "$c/state/night-shift/TST-1.report.md" 2>&1)" "\`claude --bg\` failed, and the worktree is removed"
  expect "the worktree removed" test ! -e "$c/projects/demo/.claude/worktrees/$NAME"
  expect "the branch deleted" not branch_exists "$WBRANCH"
  expect "its settings removed" test ! -e "$c/state/night-shift/TST-1.settings"
  rm "$c/claude-fail"
  jq '.updatedAt = "2026-10-04T09:00:00.000Z"
    | .history.nodes += [{createdAt: "2026-10-04T09:00:00.000Z", actorId: "user-nick", botActor: null,
    addedLabelIds: ["label-agent"], updatedDescription: null, fromTitle: null}]' \
    "$c/linear/issues/issue-1.json" >"$c/tmp/issue.json"
  mv "$c/tmp/issue.json" "$c/linear/issues/issue-1.json"
  nsw run
  expect "labelled again, it starts afresh" is "$(jq -r .phase "$c/state/night-shift/TST-1.json" 2>&1)" running
}

# A daemon a setup command starts must not hold the run's lock.
case_work_bootstrap_lock() {
  work
  jq '.repos.TST.bootstrap = ["if { true >&9; } 2>/dev/null; then touch fd9-open; fi"]' "$c/config.json" >"$c/tmp/config.json"
  mv "$c/tmp/config.json" "$c/config.json"
  nsw run
  expect "exit 0" is "$status" 0
  expect "started" is "$(jq -r .phase "$c/state/night-shift/TST-1.json" 2>&1)" running
  expect "setup ran without the lock's descriptor" test ! -e "$c/projects/demo/.claude/worktrees/$NAME/fd9-open"
}

case_work_land_busy() {
  work '.state = {name: "Done", type: "completed"}'
  work_agent waiting
  jq --arg wt "$WT" '. + [{id: "job-2", sessionId: "session-2", name: "a copy", cwd: $wt, state: "running"}]' \
    "$c/roster.json" >"$c/roster.tmp"
  mv "$c/roster.tmp" "$c/roster.json"
  jq -nc --arg sha "$(g -C "$WT" rev-parse HEAD)" \
    '[{number: 7, url: "https://github.com/test/demo/pull/7", headRefOid: $sha}]' >"$c/gh-prs"
  g -C "$c/projects/demo" remote set-url origin git@github.com:test/demo.git
  nsw run
  expect "exit 0" is "$status" 0
  expect "the worktree kept" test -d "$WT"
  expect "and the settings its sessions use" test -e "$c/state/night-shift/TST-1.settings"
  expect "a notification saying so" notified "merged, worktree kept"
}

# Parked and unchanged in Linear: not asked about at all.
case_work_waiting_quiet() {
  work '.state = {name: "In Progress", type: "started"}'
  work_agent waiting
  nsw run
  expect "exit 0" is "$status" 0
  expect "not asked about" none '.tool == "linear" and .op == "issue"'
  expect "not resumed" none '.tool == "claude" and .args[0] == "--bg"'
}

# Merged, with what setup left untracked in the worktree, as git-lfs's hooks
# under a relative hooksPath: <extra> is anything else left there.
merged_with_setup_leftovers() {
  work '.state = {name: "Done", type: "completed"}'
  work_agent waiting
  jq '.setup = ["?? .husky/_/pre-push"]' "$c/state/night-shift/TST-1.json" >"$c/tmp/state.json"
  mv "$c/tmp/state.json" "$c/state/night-shift/TST-1.json"
  mkdir -p "$WT/.husky/_"
  echo 'git lfs pre-push "$@"' >"$WT/.husky/_/pre-push"
  jq -nc --arg sha "$(g -C "$WT" rev-parse HEAD)" \
    '[{number: 7, url: "https://github.com/test/demo/pull/7", headRefOid: $sha}]' >"$c/gh-prs"
  g -C "$c/projects/demo" remote set-url origin git@github.com:test/demo.git
}

case_work_land_setup_leftovers() {
  merged_with_setup_leftovers
  nsw run
  expect "exit 0" is "$status" 0
  expect "the worktree removed, setup's files with it" test ! -e "$WT"
  expect "the branch deleted" not branch_exists "$WBRANCH"
  expect "the session removed" one '.tool == "claude" and .args == ["rm", "job-1"]'
  expect "the settings removed" test ! -e "$c/state/night-shift/TST-1.settings"
  expect "no notification" none '.tool == "notify"'
}

case_work_land_dirty() {
  merged_with_setup_leftovers
  echo "not committed" >"$WT/notes.txt"
  nsw run
  expect "exit 0" is "$status" 0
  expect "the worktree kept" test -d "$WT"
  expect "the agent's file kept" test -f "$WT/notes.txt"
  expect "the log names the agent's file" has "$(<"$c/out")" "?? notes.txt"
  expect "and not setup's" lacks "$(<"$c/out")" "?? .husky/_/pre-push"
  expect "a notification" notified "merged, worktree kept"
  expect "the settings kept for the session" test -f "$c/state/night-shift/TST-1.settings"
  nsw status
  expect "status lists them" has "$(<"$c/out")" "TST-1  merged, but its worktree and session were kept"
}

# A file the agent adds inside a directory setup made is still the agent's.
case_work_land_inside_setup_dir() {
  merged_with_setup_leftovers
  echo "the agent's" >"$WT/.husky/_/notes.txt"
  nsw run
  expect "exit 0" is "$status" 0
  expect "the worktree kept" test -f "$WT/.husky/_/notes.txt"
  expect "the log names it" has "$(<"$c/out")" "?? .husky/_/notes.txt"
}

case_work_land_gh_fails() {
  work '.state = {name: "Done", type: "completed"}'
  work_agent waiting
  touch "$c/gh-fail"
  g -C "$c/projects/demo" remote set-url origin git@github.com:test/demo.git
  nsw run
  expect "exit 0" is "$status" 0
  expect "the worktree kept" test -d "$WT"
  expect "the issue kept" test -e "$c/state/night-shift/TST-1.json"
  expect "says it will ask again" has "$(<"$c/out")" "gh could not say whether TST-1 merged"
}

case_work_canceled() {
  work '.state = {name: "Canceled", type: "canceled"}'
  work_agent waiting
  nsw run
  expect "exit 0" is "$status" 0
  expect "the issue forgotten" test ! -e "$c/state/night-shift/TST-1.json"
  expect "the worktree kept, for Nick" test -d "$WT"
}

case_work_tick() {
  local n
  work
  for n in 1 2 3; do
    nsw NIGHT_SHIFT_KEY_CMD=false _tick
    expect "tick $n: exit 0" is "$status" 0
  done
  expect "a failing run counted" is "$(cat "$c/state/night-shift/failed-runs" 2>&1)" 3
  expect "one notification on the third" one '.tool == "notify" and .title == "Night shift is failing"'
  expect "pointing at the log" has "$(jq -rs 'map(select(.tool == "notify")) | first | .body' "$c/log.jsonl")" "$c/night-shift.log says why."
}

# _tick leaves caffeinate running in the background, so its log line may
# lag the tick's own return.
caffeinated() {
  local n
  for n in {1..50}; do
    (($(requests '.tool == "caffeinate"') == 0)) || break
    sleep 0.1
  done
  one '.tool == "caffeinate" and .args == ["-s", "-t", "660"]'
}

case_work_tick_awake() {
  work '.state = {name: "In Progress", type: "started"}'
  work_agent running
  nsw NIGHT_SHIFT_INTERVAL=600 _tick
  expect "exit 0" is "$status" 0
  expect "kept awake on AC power until a minute past the next tick" caffeinated
}

case_work_tick_waiting() {
  work '.state = {name: "In Progress", type: "started"}'
  work_agent waiting
  nsw NIGHT_SHIFT_INTERVAL=600 _tick
  expect "exit 0" is "$status" 0
  sleep 0.5
  expect "left to sleep" none '.tool == "caffeinate"'
}

# safe: claude here, in the agents' sandbox, with the repository's additions
# from the config, and nothing written in the checkout.
case_work_safe() {
  work
  local r=$c/projects/demo call file
  mkdir -p "$c/home/.claude" "$r/.claude"
  echo '{"enabledPlugins": {"lsp@x": true}}' >"$r/.claude/settings.local.json"
  # Each case runs in a subshell of its own, so its cd stays there.
  cd "$r"
  nsw safe --model test
  expect "exit 0" is "$status" 0
  call=$(jq -sc 'map(select(.tool == "claude")) | first' "$c/log.jsonl")
  file=$(jq -r '.args[1]' <<<"$call")
  expect "claude in the checkout" is "$(realpath "$(jq -r .cwd <<<"$call")")" "$(realpath "$r")"
  expect "with its settings, no MCP servers, and the arguments given" is "$(jq -c '.args[2:]' <<<"$call")" \
    '["--strict-mcp-config","--model","test"]'
  expect "the settings under the state directory" has "$file" "$c/state/night-shift/safe."
  expect "and gone once the session ended" test ! -e "$file"
  expect "hooks off" is "$(jq -r .disableAllHooks "$c/settings-given.json" 2>&1)" true
  expect "the checkout's plugin off" is "$(jq -r '.enabledPlugins."lsp@x"' "$c/settings-given.json" 2>&1)" false
  expect "the repository's host added" is "$(jq -c .sandbox.network.allowedDomains "$c/settings-given.json" 2>&1)" '["github.com","pypi.org"]'
  expect "the checkout's own settings left as they were" is "$(cat "$r/.claude/settings.local.json")" '{"enabledPlugins": {"lsp@x": true}}'
  no_linear_writes
}

# Outside any repository the config names, and with no config at all: the
# base alone.
case_work_safe_elsewhere() {
  mkdir -p "$c/tmp/plain"
  cd "$c/tmp/plain"
  nsw safe
  expect "exit 0" is "$status" 0
  expect "claude started" one '.tool == "claude"'
  expect "the base's hosts only" is "$(jq -c .sandbox.network.allowedDomains "$c/settings-given.json" 2>&1)" '["github.com"]'
}

# Refused as an agent's start is, and forge's sessions are sandboxed anyway.
case_work_safe_refused() {
  work
  local r=$c/projects/demo
  mkdir -p "$r/.claude"
  echo '{"sandbox": {"excludedCommands": ["docker *"]}}' >"$r/.claude/settings.local.json"
  cd "$r"
  nsw safe
  expect "exit 1" is "$status" 1
  expect "says why" has "$(<"$c/out")" "would change the sandbox or run a command outside it: $(realpath "$r")/.claude/settings.local.json"
  expect "no claude" none '.tool == "claude"'
  ns safe
  expect "forge: exit 1" is "$status" 1
  expect "forge: says why" has "$(<"$c/out")" "safe is work mode's"
}

case_work_tick_unconfigured() {
  nsw _tick
  expect "exit 0" is "$status" 0
  expect "no run" none '.tool == "linear"'
  expect "nothing counted" test ! -e "$c/state/night-shift/failed-runs"
}

case_work_file() {
  work
  nsw file
  expect "refused" is "$status" 1
  expect "says why" has "$(<"$c/out")" "file is forge's"
}

# --- Running them ------------------------------------------------------------------

cases=(
  "land_clean        land: merged at the tip, clean, sessions done: all removed, Done"
  "land_moved_tip    land: the tip moved past the merged head: all kept"
  "land_dirty        land: a change not committed: all kept"
  "land_busy         land: a session still running: all kept"
  "start_not_creator start: created by someone else: Needs you"
  "start_not_queuer  start: queued last by someone else: Needs you"
  "start_no_actor    start: queued last with no actor recorded: Needs you"
  "start_long_history start: history with another page: Needs you"
  "start_no_repo_label start: no repo label: Needs you"
  "start             start: worktree with no upstream, issue text, claude --bg, Running, kept awake"
  "start_created_queued start: created into Queued by you: started"
  "start_battery     start: on battery: started, forge let sleep"
  "finish_handoff    finish: handoff: Handoff ready, archived, waiting, forge let sleep"
  "finish_blocked    finish: blocked: Needs you"
  "finish_quiet      finish: no result past the stall hours of work: Needs you"
  "finish_working    finish: no result within the stall hours: left alone"
  "finish_asleep     finish: hours asleep count as one tick: left alone"
  "finish_ended      finish: session ended with no result: Needs you on the second look"
  "finish_prompt     finish: session waiting on a prompt: Needs you, saying so"
  "finish_roster_gap finish: ended, then gone from the roster: the end seen stands"
  "finish_late       finish: a result after it was flagged: taken"
  "finish_waiting    finish: waiting with no result: left alone"
  "awake_offline     run: Linear down, on battery: fails, forge let sleep"
  "finish_requeued   finish: re-queued meanwhile: a comment, left in Queued"
  "finish_requeued_resumes finish: re-queued meanwhile: run resumes it"
  "finish_requeued_slow_stop finish: re-queued, the roster slow to see the stop: resume waits"
  "file_unknown_key  file: an unknown key: nothing filed"
  "file_control      file: a control character: nothing filed"
  "file_no_title     file: no title: nothing filed"
  "file_interactive  file: a terminal answers y, then n: one filed, one kept"
  "after             _after: a push on the third failure, once, reset by success"
  "after_push_failed _after: a push that failed is tried again"
  "tidy_refused      tidy: GitHub's 403 ends its questions for the run"
  "work_start        work: set up, sandboxed claude --bg, In Progress, no comment"
  "work_start_not_labeler work: labelled by a teammate: refused, said once"
  "work_start_bot    work: labelled by an integration: refused"
  "work_start_not_assignee work: assigned to someone else: refused"
  "work_start_edited work: text changed by a teammate after the label: refused"
  "work_start_relabelled work: refused, then labelled again by Nick: started"
  "work_bootstrap_fails work: setup fails: refused, worktree removed"
  "work_overrides    work: repo settings change the sandbox: refused"
  "work_helper       work: the branch's settings name a helper command: refused"
  "work_helper_user  work: Nick's own settings name a helper command: started"
  "work_setup_tracked work: a tracked file setup changed is not recorded as setup's"
  "work_finish_handoff work: handoff: notification and report, nothing in Linear"
  "work_finish_blocked work: blocked: report says how to answer"
  "work_resume       work: night-shift resume: resumed with the answer"
  "work_resume_relabelled work: labelled again while waiting: resumed once"
  "work_resume_now   work: resume starts launchd's run at once"
  "work_resume_no_job work: resume with no job, or one launchctl cannot find: next run"
  "work_land         work: completed and merged per gh: all removed, nothing in Linear"
  "work_land_gh_fails work: gh fails: all kept"
  "work_canceled     work: canceled: forgotten, worktree kept"
  "work_tick         work: _tick: three failed runs, one notification"
  "work_tick_unconfigured work: _tick with no config: nothing, no failure"
  "work_tick_awake   work: _tick with an agent at work: the Mac kept awake"
  "work_tick_waiting work: _tick with an agent waiting on Nick: left to sleep"
  "work_safe         work: safe: claude here, sandboxed, the checkout untouched"
  "work_safe_elsewhere work: safe outside a configured repository: the base alone"
  "work_safe_refused work: safe refused for settings that change the sandbox, and on forge"
  "work_file         work: file is refused"
  "start_poisoned_head start: origin/HEAD pointed at an agent's branch: made from origin's"
  "work_start_poisoned_head work: origin/HEAD pointed at an agent's branch: made from origin's"
  "work_bg_fails     work: claude --bg fails: removed, and starts afresh when labelled again"
  "work_bootstrap_lock work: setup runs without the run lock's descriptor"
  "work_land_busy    work: merged but a session at work: kept, with its settings"
  "work_waiting_quiet work: waiting and unchanged in Linear: not even asked about"
  "work_land_setup_leftovers work: merged, only setup's files untracked: all removed"
  "work_land_dirty   work: merged, the agent's file untracked: kept, and status says so"
  "work_land_inside_setup_dir work: merged, the agent's file in setup's directory: kept"
)

failed=()
skipped=0
for entry in "${cases[@]}"; do
  read -r name what <<<"$entry"
  dir=$work/$name
  # In the background and waited for, so errexit holds inside the case: a
  # step of its setup that fails ends the case, as a failure.
  (
    begin "$dir"
    "case_$name"
    expect "no request the stubs do not know" none '.tool == "unknown" or .op == "unknown" or .op == "no key"'
  ) >"$work/$name.report" 2>&1 &
  rc=0
  wait $! || rc=$?
  if ((rc == 0)) && [[ -e $dir/skipped ]]; then
    echo "skip $what: $(<"$dir/skipped")"
    skipped=$((skipped + 1))
  elif ((rc == 0)) && [[ ! -e $dir/failed ]]; then
    echo "ok   $what"
  else
    echo "FAIL $what"
    ((rc == 0)) || echo "    the case itself failed, exit $rc"
    sed 's/^/  /' "$work/$name.report"
    if [[ -s $dir/out ]]; then
      echo "    night-shift said:"
      tail -n 20 "$dir/out" | sed 's/^/      /'
    fi
    failed+=("$name")
  fi
done

if ((${#failed[@]})); then
  echo "${#failed[@]} of ${#cases[@]} night-shift cases failed: ${failed[*]}"
  exit 1
fi
if ((skipped)); then
  echo "$((${#cases[@]} - skipped)) night-shift cases pass, $skipped skipped"
else
  echo "all ${#cases[@]} night-shift cases pass"
fi
