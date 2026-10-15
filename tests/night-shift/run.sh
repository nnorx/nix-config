#!/usr/bin/env bash
# Runs hosts/forge/night-shift.sh against stubbed Linear, GitHub, ntfy and
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
# systemctl, and say how they answer; everything else is real, git included. Nothing reaches
# the network, the real claude, or Nick's own state directory.
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
script=$(realpath -- "${NIGHT_SHIFT_SCRIPT:-$root/hosts/forge/night-shift.sh}")

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
path=$bin:$PATH
for tool in curl claude systemd-run bwrap systemctl; do
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
