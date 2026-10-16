# The night shift: issues Nick queues in Linear, worked by background Claude
# Code agents, each ending in a PR handoff for him to publish. See
# hosts/forge/night-shift.nix and home/night-shift.nix for how it runs, and
# docs/night-shift.md for using it. Built with writeShellApplication, which
# adds the shebang, errexit, nounset and pipefail.
#
# Two modes, from NIGHT_SHIFT_MODE. forge, the default and what this header
# describes, runs on forge against Nick's own Linear team, with states of his
# own. work runs on a Mac against a team he shares, whose workflow is not his
# to change: "Work mode" below says how it differs. NIGHT_SHIFT_PLATFORM,
# linux or darwin, says how agents are started and how Nick is told.
#
# In forge mode, an issue moves through the team's states:
#
#   Queued         Nick put it there. Taken when a slot is free, highest
#                  priority first, but only if Nick himself created it and
#                  moved it there.
#   Running        An agent has it, in its own worktree and session.
#   Handoff ready  The agent committed and wrote a PR handoff. The comment
#                  says what changed, and for nix-config, preflight's verdict.
#   Needs you      The agent stopped with questions, or went quiet.
#   Done           Nick merged the PR. The next run sees it on GitHub, moves
#                  the issue to the team's completed state and cleans up
#                  after the agent (land_one).
#
# Moving an issue back to Queued resumes its agent's session, in the same
# worktree, with Nick's comments since it stopped. Moved there while the
# agent still works, it stays in Queued and is resumed once the result is in.
#
# Nothing here publishes, merges or deploys. Agents run in Claude Code's
# sandbox under Nick's settings; only this script, outside it, talks to Linear.

usage() {
  cat >&2 <<'EOF'
usage: night-shift run      take finished work back to Linear, then start queued work
       night-shift file     create Linear issues from drafts in each repo's .git/linear-handoff/
       night-shift check    confirm the key, states, repo labels and tools
       night-shift status   what each issue's agent is doing
       night-shift resume <ID> <answer>
                            work mode: resume an agent that stopped, with your answer
       night-shift safe [claude args]
                            work mode: claude here, in the agents' sandbox
EOF
  exit 64
}

die() {
  echo "night-shift: $*" >&2
  exit 1
}

QUEUED="Queued"
RUNNING="Running"
READY="Handoff ready"
NEEDS="Needs you"
# Opens every comment this posts. The key acts as Nick, so this is how its
# comments are told apart from his when collecting his answers.
MARKER="**Night shift**"

mode=${NIGHT_SHIFT_MODE:-forge}
platform=${NIGHT_SHIFT_PLATFORM:-linux}
[[ $mode == forge || $mode == work ]] || die "NIGHT_SHIFT_MODE is forge or work, not '$mode'"
[[ $platform == linux || $platform == darwin ]] || die "NIGHT_SHIFT_PLATFORM is linux or darwin, not '$platform'"
projects=${NIGHT_SHIFT_PROJECTS:-$HOME/projects}
max=${NIGHT_SHIFT_MAX:-2}
stall_hours=${NIGHT_SHIFT_STALL_HOURS:-4}
failed_runs=${NIGHT_SHIFT_FAILED_RUNS:-3}
state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/night-shift
power_dir=${NIGHT_SHIFT_POWER:-/sys/class/power_supply}
# Seconds between runs, forge's timer's or the Mac's launchd schedule, each
# passing its own. The most one run adds to an agent's working time (quiet)
# is twice that, and an ended session counts as quiet on two looks `settle`
# apart.
interval=${NIGHT_SHIFT_INTERVAL:-600}
[[ $interval =~ ^[1-9][0-9]*$ ]] || die "NIGHT_SHIFT_INTERVAL is a number of seconds, not '$interval'"
tick=$((2 * interval))
settle=$((5 * 60))
shopt -s nullglob

now() { date -u +%FT%TZ; }

# Read once and never exported, so the agents started below do not inherit
# it. It reaches curl through a file descriptor rather than the command line,
# which any of Nick's processes could read from /proc. From a file, sops's on
# forge, or from the output of NIGHT_SHIFT_KEY_CMD, the login keychain's on a
# Mac, which commands in the sandbox cannot read (lib/claude-sandbox.nix).
key=""
load_key() {
  if [[ -n ${NIGHT_SHIFT_KEY_CMD:-} ]]; then
    key=$("$BASH" -c "$NIGHT_SHIFT_KEY_CMD" </dev/null) && [[ -n $key ]] ||
      die "no Linear key from '$NIGHT_SHIFT_KEY_CMD'; docs/night-shift.md says how to store it"
    return 0
  fi
  [[ -r ${NIGHT_SHIFT_KEY_FILE:-} ]] || die "cannot read the Linear key at '${NIGHT_SHIFT_KEY_FILE:-}'"
  key=$(<"$NIGHT_SHIFT_KEY_FILE")
}

# gql <query> [variables json]: the response's data. Exits 1 when Linear did
# not answer, 2 when it says what was asked for does not exist, so a caller
# can tell "gone" from "offline", and 3 on any other error it answers with,
# a rate limit say, when nothing was changed.
gql() {
  local body out
  body=$(jq -nc --arg q "$1" --argjson v "${2:-"{}"}" '{query: $q, variables: $v}')
  if ! out=$(curl -sS --max-time 30 -K <(printf 'header = "Authorization: %s"\n' "$key") \
    -H 'Content-Type: application/json' --data-binary "$body" \
    https://api.linear.app/graphql); then
    echo "night-shift: Linear did not answer" >&2
    exit 1
  fi
  if jq -e '.errors' <<<"$out" >/dev/null; then
    echo "night-shift: Linear: $(jq -r '.errors | map(.message) | join("; ")' <<<"$out")" >&2
    if jq -e '.errors | all(.message | test("not found"; "i"))' <<<"$out" >/dev/null; then
      exit 2
    fi
    exit 3
  fi
  jq -c '.data' <<<"$out"
}

# notify <title> <message> [url]. Fails when the push did not go out, which
# only after_run acts on: elsewhere a missed push leaves the issue itself
# correct. The topic is the only access control, so it goes through a
# descriptor too.
#
# On a Mac, a notification on the desktop instead, with no URL to open. The
# text reaches AppleScript as arguments to its run handler, never as part of
# the script, so nothing in it can make osascript do more than show it.
notify() {
  if [[ $platform == darwin ]]; then
    osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
      -e 'end run' "$1" "$2" </dev/null >/dev/null || {
      echo "night-shift: notification failed for: $1" >&2
      return 1
    }
    return 0
  fi
  [[ -r ${NIGHT_SHIFT_NTFY_FILE:-} ]] || return 0
  local click=()
  [[ -z ${3-} ]] || click=(-H "Click: $3")
  curl -fsS --max-time 15 -o /dev/null \
    -K <(printf 'url = %s\n' "$(<"$NIGHT_SHIFT_NTFY_FILE")") \
    -H "Title: $1" "${click[@]}" -H "Tags: robot" --data-binary "$2" || {
    echo "night-shift: ntfy failed for: $1" >&2
    return 1
  }
}

# One issue in full. The whole history, in whatever order Linear returns it,
# so the check on who queued it does not depend on the order.
ISSUE_FIELDS='id identifier title description url
  state { name type }
  creator { id }
  team { states { nodes { id name type position } } }
  labels { nodes { name parent { name } } }
  comments(first: 100) { nodes { body createdAt user { id } } }
  history(first: 250) { pageInfo { hasNextPage } nodes { createdAt actorId toState { name } } }'

# Work mode's: the assignee, the team's key, which names its repository in the
# config, and from the history who added which label and who edited the text,
# for work_refusal. A query of its own rather than more fields on forge's, so a
# field Linear renames breaks only the mode that asks for it.
WORK_FIELDS='id identifier title description url createdAt updatedAt
  state { name type }
  creator { id }
  botActor { id }
  assignee { id }
  team { key states { nodes { id name type position } } }
  labels { nodes { id name } }
  comments(first: 100) { nodes { body createdAt user { id } } }
  history(first: 250) { pageInfo { hasNextPage }
    nodes { createdAt actorId botActor { id } addedLabelIds updatedDescription fromTitle } }'

issue() {
  local fields=$ISSUE_FIELDS
  [[ $mode == forge ]] || fields=$WORK_FIELDS
  gql "query(\$id: String!) { issue(id: \$id) { $fields } }" \
    "$(jq -nc --arg id "$1" '{id: $id}')" | jq -c '.issue'
}

# move <issue json> <state name>
move() {
  local state
  state=$(jq -r --arg s "$2" '.team.states.nodes[] | select(.name == $s) | .id' <<<"$1")
  [[ -n $state ]] || die "$(jq -r .identifier <<<"$1")'s team has no state '$2'; see night-shift check"
  # shellcheck disable=SC2016 # GraphQL's variables, not the shell's
  gql 'mutation($id: String!, $s: String!) { issueUpdate(id: $id, input: {stateId: $s}) { success } }' \
    "$(jq -nc --arg id "$(jq -r .id <<<"$1")" --arg s "$state" '{id: $id, s: $s}')" >/dev/null
}

# comment <issue json> <markdown>
comment() {
  # shellcheck disable=SC2016 # GraphQL's variables, not the shell's
  gql 'mutation($id: String!, $b: String!) { commentCreate(input: {issueId: $id, body: $b}) { success } }' \
    "$(jq -nc --arg id "$(jq -r .id <<<"$1")" --arg b "$MARKER"$'\n\n'"$2" '{id: $id, b: $b}')" >/dev/null
}

# stop_issue <issue json> <state> <markdown> <what happened>. The push names
# the issue by its identifier, and a tap opens its URL. Never by its title:
# ntfy.sh is a third party, and a title can describe the house.
#
# In work mode the issue is left as it is, since teammates read it: the text
# goes to $state_dir/<ID>.report.md, which `night-shift status` shows, under
# what the state would have been.
stop_issue() {
  local ident
  ident=$(jq -r .identifier <<<"$1")
  if [[ $mode == work ]]; then
    write_report "$ident" "$2" "$3"
  else
    comment "$1" "$3"
    move "$1" "$2"
  fi
  notify "Night shift" "$ident: $4" "$(jq -r .url <<<"$1")" || true
  echo "night-shift: $ident: $4"
}

# write_report <ident> <heading> <markdown>: work mode's comment, kept here.
write_report() {
  mkdir -p "$state_dir"
  printf '# %s: %s\n\n_%s_\n\n%s\n' "$1" "$2" "$(now)" "$3" >"$state_dir/$1.report.md"
}

# Nick's comments, oldest first, after <since> when given, without this
# script's own.
answers() {
  jq -r --arg since "${2:-}" --arg me "$viewer" --arg marker "$MARKER" '
    [.comments.nodes[]
     | select(.user.id == $me and (.body | startswith($marker) | not))
     | select($since == "" or .createdAt > $since)]
    | sort_by(.createdAt)
    | map("[\(.createdAt[:16] | sub("T"; " "))] \(.body)") | join("\n\n")' <<<"$1"
}

result_path() {
  echo "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)/night-shift/$2.md"
}

# Keeps a result that has been read, or that turned up too late, out of the
# way of the next one.
archive() {
  [[ ! -f $1 ]] || mv "$1" "$1.$(date +%s)"
}

# write_issue <issue json> <result path>: the issue as the agent is handed it,
# as <ID>.issue.md next to its result, for a session reviewing the branch. The
# Linear key is out of Claude's reach, so this is how it reads the task. Nick's
# plan text, so it stays under .git/ and nothing publishes it. Written before
# claude starts, so a run that fails to start still leaves it.
write_issue() {
  local comments
  comments=$(answers "$1")
  mkdir -p "$(dirname "$2")"
  cat >"${2%.md}.issue.md" <<EOF
# $(jq -r '"\(.identifier): \(.title)"' <<<"$1")

- URL: $(jq -r .url <<<"$1")
- State: $(jq -r .state.name <<<"$1")
- Handed to the agent: $(now)

$(jq -r '.description // "(no description)"' <<<"$1")

## Nick's comments on the issue, oldest first

${comments:-(none)}
EOF
}

# backlog: every open issue, by state, then priority, written to
# $state_dir/backlog.md after each run and each `night-shift file`. A Claude
# session cannot reach Linear, and is deliberately not given a key: one acting
# as Nick could create and queue issues, which the dispatcher would then take
# as his. This is how a session reads what is filed instead, with no way to
# write. Nick's plan text, like write_issue's, so it stays outside every repo.
#
# Called after the real work, with failure reported rather than fatal, so a
# Linear quirk here never fails a run (and never counts toward after_run's
# push). Pages are collected in a file, not a variable, since descriptions
# could pass the limit on a single argument.
backlog() {
  local out=$state_dir/backlog.md tmp after="" page more
  mkdir -p "$state_dir"
  tmp=$(mktemp "$out.XXXXXX") || return 1
  while :; do
    # shellcheck disable=SC2016 # GraphQL's variables, not the shell's
    page=$(gql 'query($after: String) {
      issues(first: 50, after: $after, filter: {state: {type: {nin: ["completed", "canceled"]}}}) {
        pageInfo { hasNextPage endCursor }
        nodes { identifier title description priority priorityLabel updatedAt
          state { name type } project { name } labels { nodes { name parent { name } } } } } }' \
      "$(jq -nc --arg a "$after" '{after: (if $a == "" then null else $a end)}')") || {
      rm -f "$tmp" "$tmp.nodes"
      return 1
    }
    jq -c '.issues.nodes[]' <<<"$page" >>"$tmp.nodes"
    more=$(jq -r '.issues.pageInfo | if .hasNextPage then .endCursor else "" end' <<<"$page")
    [[ -n $more ]] || break
    after=$more
  done
  # shellcheck disable=SC2016 # jq's variables, not the shell's
  jq -rs --arg now "$(now)" '
    def stage: {started: 0, unstarted: 1, backlog: 2, triage: 3}[.state.type] // 4;
    def rank: if .priority == 0 then 5 else .priority end;
    def number: .identifier | capture("(?<n>[0-9]+)$").n | tonumber;
    def labels: [.labels.nodes[] | select(.parent.name != "repo") | .name];
    def repo: [.labels.nodes[] | select(.parent.name == "repo") | .name] | first // "none";
    sort_by(stage, .state.name, rank, number)
    | "# Open issues in Linear",
      "",
      "Written by night-shift at \($now): \(length) issues not done or canceled,",
      "by state, then priority. A snapshot to read; change issues in Linear.",
      (group_by(stage, .state.name) | sort_by(.[0] | stage, .state.name)[]
        | "", "## \(.[0].state.name) (\(length))",
          (.[] | "", "### \(.identifier): \(.title)", "",
            "- Priority: \(.priorityLabel). Repo: \(repo). Project: \(.project.name // "none")."
              + (if labels == [] then "" else " Labels: \(labels | join(", "))." end),
            "- Updated: \(.updatedAt[:10])",
            "",
            # Quoted, so a heading in a description cannot pass for one of
            # the headings above.
            (.description // "(no description)" | rtrimstr("\n") | split("\n")
              | map(if . == "" then ">" else "> " + . end) | join("\n"))))
  ' "$tmp.nodes" >"$tmp" || {
    rm -f "$tmp" "$tmp.nodes"
    return 1
  }
  rm -f "$tmp.nodes"
  mv "$tmp" "$out"
}

# forget <state file> [why]: drops an issue the dispatcher is done with, along
# with its issue text and results, read or not, unless the repo is gone too.
forget() {
  local f=$1 ident dir
  ident=$(jq -r .ident "$f")
  if dir=$(git -C "$(jq -r .repo "$f")" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    rm -f "$dir/night-shift/$ident.issue.md" "$dir/night-shift/$ident.md" "$dir/night-shift/$ident.md".*
  fi
  # Work mode's, beside the state file.
  # Not the settings an agent's session was started with, which it reads
  # again on every resume and which may outlive this, a session kept by
  # land_one say; land_one removes them with the session.
  rm -f "$state_dir/$ident".{report.md,answer,bootstrap.log}
  rm "$f"
  echo "night-shift: forgot $ident${2:+, $2}"
}

# update <state file> <jq filter> [jq args...]
update() {
  local f=$1 filter=$2
  shift 2
  jq "$@" "$filter" "$f" >"$f.tmp"
  mv "$f.tmp" "$f"
}

# claude in a scope of its own, outside the unit, and without the run lock's
# descriptor. Any claude command can start the background daemon, which hosts
# every agent: in the unit's cgroup, stopping or finishing a run would kill
# them, and holding the lock it would keep every later run out.
#
# --expand-environment=no, because systemd-run otherwise expands "${...}" in
# its arguments the way ExecStart= does, and the prompt is one of them. An
# issue quoting a workflow's ${{ github.ref }} or a shell's "${args[@]}" reached
# the agent with those emptied, and a name that is set, ${HOME} say, would
# reach it as its value. The prompt has to arrive as Nick wrote it.
#
# On a Mac there is no cgroup to leave: launchd lets processes outlive the run
# because the agent sets AbandonProcessGroup (home/night-shift.nix). The
# run's deadline (_tick) ends the run's whole process group, so claude starts
# in a group of its own, as a job under job control, and its daemon is left
# be. Job control goes off again before the wait, which would otherwise print
# the job's end.
cl() {
  if [[ $platform == darwin ]]; then
    (
      set -m
      claude "$@" 9>&- &
      set +m
      wait $!
    )
  else
    systemd-run --user --scope --collect --quiet --expand-environment=no -- claude "$@" 9>&-
  fi
}

closed() {
  [[ $(jq -r .state.type <<<"$1") == completed || $(jq -r .state.type <<<"$1") == canceled ]]
}

# agent <name> <worktree>: "<id> <sessionId> <state>" of the background agent
# with that name in that worktree, or nothing. The session id is what --resume
# takes, the short id what `claude stop` takes. `claude --bg` picks both itself
# and ignores --session-id, so this asks its roster rather than choosing one.
agent() {
  cl agents --json --all </dev/null 2>/dev/null |
    jq -r --arg n "$1" --arg wt "$2" \
      'map(select(.name == $n and .cwd == $wt)) | last | select(.) | "\(.id) \(.sessionId) \(.state)"' || true
}

# The roster's states for a session no longer at work: finished, stopped, or
# waiting on a prompt. Anything else counts as working. quiet, a resume and
# land_one all go by this one list.
ENDED="done blocked stopped failed"

at_work() {
  [[ " $ENDED " != *" $1 "* ]]
}

# quiet <state file> <name> <worktree>: why a running agent with no result
# counts as quiet, or nothing, and status 1, while it is still at work. Either:
#
# - Its session has ended without writing a result, or waits on a prompt,
#   on two looks `settle` apart. One look is not enough to be sure the agent
#   will not carry on.
# - It has worked `stall_hours` with the machine awake. Each run adds the time
#   since the last, but at most `tick`, so hours it spent asleep, when no run
#   came, count as one tick. On a wall clock, a night asleep reads as a night
#   of silence, and agents still at work were flagged as soon as forge woke.
quiet() {
  local f=$1 t last worked st="" ended=""
  t=$(date +%s)
  last=$(date -d "$(jq -r '.ticked // .started' "$f")" +%s)
  worked=$(($(jq -r '.worked // 0' "$f") + (t - last < tick ? (t > last ? t - last : 0) : tick)))
  read -r _ _ st <<<"$(agent "$2" "$3")" || true
  # A roster that does not list the session, or could not be read, says
  # nothing either way, so an end already seen stands.
  if [[ -z $st ]]; then
    ended=$(jq -r '.ended // ""' "$f")
    st=$(jq -r '.ended_as // ""' "$f")
  elif ! at_work "$st"; then
    ended=$(jq -r --arg now "$(now)" '.ended // $now' "$f")
  fi
  # shellcheck disable=SC2016 # jq's variables, not the shell's
  update "$f" '.worked = $w | .ticked = $now
    | if $e == "" then del(.ended, .ended_as) else .ended = $e | .ended_as = $s end' \
    --argjson w "$worked" --arg now "$(now)" --arg e "$ended" --arg s "$st"
  if [[ -n $ended ]] && ((t - $(date -d "$ended" +%s) >= settle)); then
    if [[ $st == blocked ]]; then
      echo "The agent is waiting on a prompt, with no result."
    else
      echo "The agent's session ended ($st) without writing a result."
    fi
  elif ((worked >= stall_hours * 3600)); then
    echo "No result after $stall_hours hours of work."
  else
    return 1
  fi
}

# on_ac: whether forge runs on mains power. A machine with no battery counts.
on_ac() {
  local s battery=""
  for s in "$power_dir"/*; do
    case $(cat "$s/type" 2>/dev/null) in
      Mains) [[ $(cat "$s/online" 2>/dev/null) != 1 ]] || return 0 ;;
      Battery) battery=1 ;;
    esac
  done
  [[ -z $battery ]]
}

# awake: keeps the machine from sleep while an agent works on AC, and only
# then. Called as a run exits, whether it got through or not. A sleeping
# machine freezes every agent until someone wakes it, so work queued for the
# night waits for the morning.
#
# On forge, Plasma suspends after 15 idle minutes whatever runs. This starts
# night-shift-awake.service, a power inhibition held by kde-inhibit
# (night-shift.nix), and stops it once nothing runs or forge is on battery,
# where it sleeps as before and the agents wait. Only idle sleep is blocked:
# the screen still locks and turns off, and a closed lid still suspends.
#
# On a Mac, caffeinate -s, which holds only on AC power, until a minute past
# the next run, which asks again; once nothing runs it lapses by then. It
# outlives the run: in a process group of its own, so a run's deadline
# (_tick) does not end it, and without the run lock's descriptor, which it
# would otherwise hold until it lapsed and keep the next run out.
awake() {
  local verb=stop
  if [[ $platform == darwin ]]; then
    if (($(running) > 0)); then
      (
        set -m
        caffeinate -s -t $((interval + 60)) </dev/null >/dev/null 2>&1 9>&- &
      )
    fi
    return 0
  fi
  if (($(running) > 0)) && on_ac; then
    verb=start
  fi
  systemctl --user "$verb" night-shift-awake.service ||
    echo "night-shift: could not $verb night-shift-awake.service" >&2
}

# What the agent's first prompt says in both modes: the task as Nick wrote
# it, two of the rules, and how to report. prompt_new and work_prompt_new put
# their own text around these, so a change here reaches both.
prompt_task() {
  local comments
  comments=$(answers "$1")
  cat <<EOP
# $(jq -r '"\(.identifier): \(.title)"' <<<"$1")

$(jq -r '.description // "(no description)"' <<<"$1")

## Nick's comments on the issue, oldest first

${comments:-(none)}
EOP
}

PROMPT_SCOPE="- Make the change the task asks for, as one pull request. If it has to grow
  beyond that, stop and ask."

PROMPT_STOP="- Stop and ask rather than guess when a decision is Nick's, when the task is
  ambiguous, or when a check fails for a reason outside the task. A stopped
  task costs him one look; one that improvised costs a review of all of it."

# prompt_finish <result path>
prompt_finish() {
  cat <<EOP
## When you finish or stop

Write $1, then end your turn:

- The first line is exactly \`handoff\` or \`blocked\`.
- After a handoff: what changed and what you verified, in a few lines.
- When blocked: what you did so far, then numbered questions, each answerable
  in a sentence.
EOP
}

prompt_new() {
  local issue=$1 repo=$2 wt=$3 branch=$4 base=$5 result=$6
  cat <<EOP
You are the night shift: an unattended Claude Code session working on a task
Nick queued in Linear. Nobody is watching. He reads what you leave when he is
next at his desk, often the next morning.

$(prompt_task "$issue")

## How to work

- You are in a git worktree of $(basename "$repo") at $wt, on branch $branch,
  made from $base. Read the repository's CLAUDE.md first. Where it and this
  prompt disagree, CLAUDE.md wins, except that you never push, merge or deploy.
$PROMPT_SCOPE
- Run the checks the repository names. Commit on this branch without renaming
  it, then write the PR handoff with the core plugin's pr-handoff skill, so
  Nick can publish it with \`pr-handoff\` from this worktree. Touch no other
  worktree.
$PROMPT_STOP

$(prompt_finish "$result")

Nick answers in Linear, and you will be resumed in this session with his
answer, so do not wait for one here.
EOP
}

prompt_resume() {
  local issue=$1 since=$2 result=$3 new lead=" without a new comment."
  new=$(answers "$issue" "$since")
  [[ -z $new ]] || lead=", with these comments since you last heard from him:"
  cat <<EOP
Nick re-queued $(jq -r .identifier <<<"$issue") in Linear$lead

${new}

Carry on under the same rules. When you finish or stop again, write $result
the same way, and end your turn.
EOP
}

slug() {
  tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//' | cut -c1-32 | sed 's/-$//'
}

# add_worktree <repo> <branch> <worktree> <base>: the agent's worktree, on a
# new branch with no upstream (start_one says why), and with no hook run.
# forge runs none anyway (home/claude.nix); a work repo's would, and with a
# relative core.hooksPath, husky's say, they come from the new worktree, which
# is the agent's to write from here on. Setup is work_bootstrap's alone.
add_worktree() {
  git -C "$1" -c core.hooksPath=/dev/null worktree add --quiet --no-track -b "$2" "$3" "$4"
}

# fetch_base <repo>: fetches origin, then prints "<branch> <commit>" for the
# branch origin's HEAD names, as origin itself answers. Not from
# refs/remotes/origin/HEAD: commands in the sandbox can write the shared refs
# (it protects .git/config and hooks, not refs), fetch never resets that one,
# and an agent that pointed it at its own branch would hand its code to the
# next agent, and in work mode to work_bootstrap, outside the sandbox. A
# commit id from origin is one nothing in the repository can forge.
#
# Without the run lock's descriptor: an SSH connection kept open for reuse
# would otherwise hold the lock for as long as it lives.
fetch_base() {
  local out branch sha
  out=$(git -C "$1" ls-remote --symref origin HEAD 9>&-) || return 1
  branch=$(sed -nE 's#^ref: refs/heads/([^[:space:]]+)[[:space:]]+HEAD$#\1#p' <<<"$out")
  sha=$(awk '$1 != "ref:" && $2 == "HEAD" { print $1 }' <<<"$out")
  [[ -n $branch && -n $sha ]] || return 1
  git -C "$1" fetch --quiet origin 9>&- || return 1
  git -C "$1" cat-file -e "$sha^{commit}" 2>/dev/null || return 1
  echo "$branch $sha"
}

# Runs a command with NIGHT_SHIFT_HIDE's paths hidden, one per line, `~` and
# globs allowed: what Claude Code's sandbox denies, and Nick's credentials
# besides (night-shift.nix). The brief evaluates the agent's branch, which is
# code the agent wrote, with the network on, since evaluation fetches flake
# inputs; what holds is that there is nothing secret left to read.
confined() {
  local args=(--dev-bind / /) p q
  while IFS= read -r p; do
    [[ -n $p ]] || continue
    while IFS= read -r q; do
      if [[ -d $q ]]; then
        args+=(--tmpfs "$q")
      else
        args+=(--ro-bind /dev/null "$q")
      fi
    done < <(compgen -G "${p/#\~/$HOME}" || true)
  done <<<"${NIGHT_SHIFT_HIDE:-}"
  bwrap "${args[@]}" -- "$@"
}

# The verdict and its findings from preflight's brief, for repos that have it.
brief() {
  local repo=$1 branch=$2 out
  [[ -f $repo/scripts/preflight-brief.jq ]] || return 0
  out=$(mktemp)
  if (cd "$repo" && confined nix run .#preflight -- --head "$branch" --json "$out" </dev/null >/dev/null 2>&1); then
    jq -r '"**Preflight: \(.verdict.level).** \(.verdict.text)",
      (.hosts | to_entries[] | .key as $h | .value.findings[]
        | select(.level != "note") | "- \($h), \(.level): \(.text)"),
      (.plan[] | select(.level != "note") | "- \(.level): \(.text)")' "$out"
  else
    echo "**Preflight failed** on this branch. Run \`nix run .#preflight -- --head $branch\` to see why."
  fi
  rm -f "$out"
}

# report: stop_issue for a result, except that an issue Nick moved back to
# Queued while its agent worked stays there. The same run then resumes it
# with his new comments, rather than leaving them unanswered.
report() {
  if [[ $mode == forge && $(jq -r .state.name <<<"$1") == "$QUEUED" ]]; then
    comment "$1" "$3"
    echo "night-shift: $(jq -r .identifier <<<"$1"): $4, left in $QUEUED"
  else
    stop_issue "$@"
  fi
}

# One running issue: take its result back to Linear, or flag it as quiet.
#
# A waiting issue's result is taken too. Results are archived once read, so
# one there now is new: Nick answered a flagged agent through `claude attach`,
# or asked a handed-off one for more, and it reported again.
finish_one() {
  local f=$1 id ident repo wt branch name result kind body i rc=0 verdict="" level session="" why="" nudge answer
  # How Nick answers: in Linear on forge, here in work mode, where the agent
  # reads nothing from the issue but what its text was when it started.
  nudge="move this back to $QUEUED to nudge it"
  answer="Answer in a comment and move this back to $QUEUED to resume it"
  if [[ $mode == work ]]; then
    nudge="\`night-shift resume $(jq -r .ident "$f") \"<what to do>\"\` nudges it"
    answer="Answer with \`night-shift resume $(jq -r .ident "$f") \"<answer>\"\` to resume it"
  fi
  id=$(jq -r .id "$f")
  ident=$(jq -r .ident "$f")
  repo=$(jq -r .repo "$f")
  result=$(result_path "$repo" "$ident")
  case $(jq -r .phase "$f") in
    running) ;;
    waiting) [[ -f $result ]] || return 0 ;;
    *) return 0 ;;
  esac
  wt=$(jq -r .worktree "$f")
  branch=$(jq -r .branch "$f")
  name=$(jq -r .name "$f")

  if [[ ! -f $result ]]; then
    why=$(quiet "$f" "$name" "$wt") || return 0
  else
    kind=$(head -n 1 "$result" | tr -d '[:space:]')
    body=$(tail -n +2 "$result")
    # Preflight first: it takes minutes, and the issue's state is read after
    # it, so a re-queue made meanwhile counts. Not in work mode, whose repos
    # have no preflight and whose Mac has no bwrap to confine one: there the
    # agent's own checks in its sandbox and CI's on the PR stand in.
    [[ $mode == work || $kind != handoff ]] || verdict=$(brief "$repo" "$branch")
    # The agent has just reported, so the roster surely lists it: keep its id
    # for a resume after the roster forgets.
    read -r _ session _ <<<"$(agent "$name" "$wt")" || true
    # shellcheck disable=SC2016 # jq's variables, not the shell's
    [[ -z ${session:-} ]] || update "$f" '.session = $s' --arg s "$session"
  fi
  i=$(issue "$id") || rc=$?
  # In work mode Linear completes an issue when its PR merges, and one that
  # waited on Nick may have reported again since, after he asked it for more
  # through `claude attach`. tidy lands it, cleaning up after the agent, as
  # this run's next step; forgetting it here would leave all that behind.
  if ((rc == 0)) && [[ $mode == work && $(jq -r .phase "$f") == waiting ]] && closed "$i"; then
    return 0
  fi
  if ((rc == 2)) || { ((rc == 0)) && closed "$i"; }; then
    # Deleted, done or canceled while the agent worked: leave it closed.
    forget "$f" "closed while running"
    return 0
  fi
  ((rc == 0)) || return "$rc"

  if [[ -n $why ]]; then
    report "$i" "$NEEDS" "$why \`claude attach $name\` shows where it is; $nudge." \
      "Went quiet"
  else
    if [[ $kind == handoff ]]; then
      # "be there" from "**Preflight: be there.** ...", for the push.
      level=$(sed -nE '1s/^\*\*Preflight: ([^.]*)\..*/ (\1)/p' <<<"$verdict")
      report "$i" "$READY" "Handoff ready on \`$branch\`.

$body
${verdict:+
$verdict
}
To publish: \`cd $wt && pr-handoff\`. To talk to the agent: \`claude attach $name\`." \
        "Handoff ready$level"
    else
      report "$i" "$NEEDS" "The agent stopped and needs you.

$body

$answer, or \`claude attach $name\`." \
        "Needs you"
    fi
    archive "$result"
  fi
  update "$f" '.phase = "waiting"'
}

# resume_agent <issue json> <state file> <prompt function>: continues the
# issue's session in its worktree, with what the function prints given the
# issue, when the agent last heard from Nick, and the result path. Returns 1,
# with the issue stopped and why, when it could not.
resume_agent() {
  local i=$1 f=$2 prompt=$3 ident repo wt name job="" session="" st="" result out copy
  ident=$(jq -r .ident "$f")
  repo=$(jq -r .repo "$f")
  wt=$(jq -r .worktree "$f")
  name=$(jq -r .name "$f")
  # The roster first; the id saved earlier covers a roster that has
  # forgotten the session.
  read -r job session _ <<<"$(agent "$name" "$wt")" || true
  [[ -n ${session:-} ]] || session=$(jq -r '.session // empty' "$f")
  if [[ -z $session ]]; then
    stop_issue "$i" "$NEEDS" "Could not find the agent's session to resume in \`$wt\`." "Did not resume"
    return 1
  fi
  result=$(result_path "$repo" "$ident")
  # finish_one took any result written before this run; one written since
  # is moot, as the resume asks for a new one.
  archive "$result"
  write_issue "$i" "$result"
  # --resume continues the session under the same id only if it is stopped
  # and given no flags; otherwise it starts a copy under a new id. A finished
  # session keeps its process, so stop it first. Its name, permission mode
  # and, in work mode, its --settings and --strict-mcp-config are saved with
  # it, and passing them again counts as new flags.
  if [[ -n ${job:-} ]]; then
    cl stop "$job" </dev/null >/dev/null 2>&1 || true
    # The roster can still call a session busy just after it stops, and a
    # resume then starts a copy, as NNO-65's did just after its session
    # exited. So wait, up to a minute, for the roster to say it has ended,
    # or to forget it.
    for _ in {1..30}; do
      read -r _ _ st <<<"$(agent "$name" "$wt")" || true
      if [[ -z $st ]] || ! at_work "$st"; then
        break
      fi
      sleep 2
    done
  fi
  if ! out=$(cd "$wt" && cl --bg --resume "$session" </dev/null \
    "$("$prompt" "$i" "$(jq -r .since "$f")" "$result")" 2>&1 >/dev/null); then
    stop_issue "$i" "$NEEDS" "Could not resume the session in \`$wt\`." "Did not resume"
    return 1
  fi
  echo "$out" >&2
  # claude says so when it started a copy instead, which would put two
  # agents in one worktree: stop it and let Nick decide. A copy keeps none of
  # the saved flags, so in work mode it is sandboxed only by the worktree's
  # own settings (work_start_one).
  copy=$(sed -nE 's/.*started a copy as ([0-9a-f]+).*/\1/p' <<<"$out" | head -n 1)
  if [[ -n $copy ]]; then
    cl stop "$copy" </dev/null >/dev/null 2>&1 || true
    stop_issue "$i" "$NEEDS" "Not resumed: claude started a copy ($copy) instead of continuing the session, and the copy was stopped. \`claude attach ${job:-$session}\` opens the original." "Did not resume"
    return 1
  fi
  # quiet's clock starts over.
  # shellcheck disable=SC2016 # jq's variables, not the shell's
  update "$f" '.phase = "running" | .started = $now | .since = $now | .session = $s | del(.worked, .ticked, .ended)' \
    --arg now "$(now)" --arg s "$session"
}

# One queued issue: start an agent on it, or resume the one it had.
start_one() {
  local id=$1 i ident queuer f label repo fb base sha name wt branch session="" result
  i=$(issue "$id")
  [[ $(jq -r .state.name <<<"$i") == "$QUEUED" ]] || return 0
  ident=$(jq -r .identifier <<<"$i")
  f=$state_dir/$ident.json

  # Whoever last moved it into Queued, or created it there. Anything synced
  # in from elsewhere, a public repo's issues say, can reach the state; only
  # Nick's own hand starts an agent. The creator stands in only when no move
  # into Queued is recorded at all: a move with no actor, as an automation or
  # integration makes, is nobody's, not the creator's.
  if [[ $(jq -r .history.pageInfo.hasNextPage <<<"$i") == true ]]; then
    stop_issue "$i" "$NEEDS" "Not started: its history is too long to tell who queued it. Start it with \`claude\` instead." "Not started"
    return 0
  fi
  queuer=$(jq -r --arg q "$QUEUED" '. as $i | [.history.nodes[] | select(.toState.name == $q)]
    | if . == [] then $i.creator.id // "" else max_by(.createdAt).actorId // "" end' <<<"$i")
  if [[ -z $queuer ]]; then
    stop_issue "$i" "$NEEDS" "Not started: Linear recorded no person moving it to $QUEUED, as for an automation's move. Only issues you move to $QUEUED yourself are taken." "Not queued by you"
    return 0
  fi
  if [[ $queuer != "$viewer" ]]; then
    stop_issue "$i" "$NEEDS" "Not started: only issues you move to $QUEUED yourself are taken." "Not queued by you"
    return 0
  fi
  # The title and description become the agent's task, given as Nick's, so
  # they must be his too. Synced and teammates' issues are not taken.
  if [[ $(jq -r '.creator.id // ""' <<<"$i") != "$viewer" ]]; then
    stop_issue "$i" "$NEEDS" "Not started: only issues you created are taken, since the agent is given the description as your task." "Not yours"
    return 0
  fi

  if [[ -f $f && $(jq -r .phase "$f") == running ]]; then
    # Re-queued while its agent works: left in Queued, and resumed with the
    # new comments once its result is in (report).
    return 0
  fi

  if [[ -f $f ]]; then
    resume_agent "$i" "$f" prompt_resume || return 0
  else
    label=$(jq -r '[.labels.nodes[] | select(.parent.name == "repo") | .name] | first // ""' <<<"$i")
    repo=$projects/$label
    if [[ ! $label =~ ^[A-Za-z0-9._-]+$ ]] || ! git -C "$repo" remote get-url origin >/dev/null 2>&1; then
      stop_issue "$i" "$NEEDS" "Not started: give it a \`repo\` label naming a repository in $projects with an \`origin\`." "No repo"
      return 0
    fi
    # Offline, say: leave it queued for the next run.
    fb=$(fetch_base "$repo") || die "$ident: could not fetch $label; trying again next run"
    read -r base sha <<<"$fb"
    base=origin/$base
    name="${ident,,}-$(jq -r .title <<<"$i" | slug)"
    wt=$repo/.claude/worktrees/$name
    branch=worktree-$name
    # --no-track: setting the branch's upstream writes .git/config, which fails
    # while a sandboxed Claude session in the repo holds its placeholder at
    # .git/config.lock. git has made the branch by then, so the next run would
    # fail on that instead. Nothing reads the upstream; pr-handoff sets its own.
    if ! add_worktree "$repo" "$branch" "$wt" "$sha"; then
      stop_issue "$i" "$NEEDS" "Not started: could not make the worktree \`$wt\` on \`$branch\`. One may be left from an earlier run." "No worktree"
      return 0
    fi
    result=$(result_path "$repo" "$ident")
    write_issue "$i" "$result"
    if ! (cd "$wt" && cl --bg -n "$name" --permission-mode auto </dev/null \
      "$(prompt_new "$i" "$repo" "$wt" "$branch" "$base" "$result")") >/dev/null; then
      stop_issue "$i" "$NEEDS" "Not started: \`claude --bg\` failed in \`$wt\`." "Did not start"
      return 0
    fi
    # May be empty if the roster lags; finish_one and a resume ask again.
    read -r _ session _ <<<"$(agent "$name" "$wt")" || true
    # since: when the agent last heard from Nick, so a resume passes on
    # every comment made after it, including those made while it worked.
    jq -n --arg id "$id" --arg ident "$ident" --arg repo "$repo" --arg worktree "$wt" \
      --arg branch "$branch" --arg name "$name" --arg session "$session" --arg now "$(now)" \
      '{id: $id, ident: $ident, repo: $repo, worktree: $worktree, branch: $branch,
        name: $name, session: $session, phase: "running", started: $now, since: $now}' >"$f.tmp"
    mv "$f.tmp" "$f"
  fi
  move "$i" "$RUNNING"
  echo "night-shift: started $ident"
}

# The GitHub repository behind <repo>'s origin, as owner/name, or nothing.
github_repo() {
  local url
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 0
  [[ $url =~ ^(https://|ssh://git@|git@)github\.com[:/]([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]] || return 0
  echo "${BASH_REMATCH[2]}/${BASH_REMATCH[3]%.git}"
}

# merged_pr <owner/name> <branch>: {number, url, sha} of the PR from <branch>
# that merged, or nothing. Asked without a token, as the pr-handoff skill
# does: the night shift has no GitHub login and must not get one (CLAUDE.md,
# "Deploying and merging"). A private repo answers 404, the same as a missing
# one, and is left to Nick. Returns 1 when GitHub did not answer, and 2 when it
# refused, which without a token is nearly always the limit of 60 an hour.
merged_pr() {
  local out code
  out=$(curl -sS --max-time 15 -w '\n%{http_code}' -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$1/pulls?state=closed&head=${1%%/*}:$(jq -rn --arg b "$2" '$b | @uri')") ||
    return 1
  code=${out##*$'\n'}
  case $code in
    200) jq -c '[.[] | select(.merged_at)] | max_by(.merged_at) | select(.)
      | {number, url: .html_url, sha: .head.sha}' <<<"${out%$'\n'*}" ;;
    404) ;;
    403 | 429) return 2 ;;
    *) return 1 ;;
  esac
}

# after_setup <state file> <status>: the lines of `git status --porcelain
# --untracked-files=all` that setup did not leave behind. Work mode records
# the untracked files setup left when it sets the worktree up
# (work_start_one): files a repository's setup writes and does not ignore,
# git-lfs's hooks under a relative core.hooksPath say, are not the agent's
# work and keep nothing. A tracked file setup changed still keeps it. File by
# file, since by default git folds an untracked directory into one line,
# which would hide a file the agent added inside one of setup's. On forge,
# every line.
after_setup() {
  grep -vxF -f <(jq -r '(.setup // [])[]' "$1") <<<"$2" || true
}

# One handoff whose PR Nick merged (tidy): clean up after its agent, then move
# it to Done. The worktree goes only when nothing in it can be lost: the
# branch's tip is the head the PR merged, so every commit is in main, nothing
# is uncommitted, and no session in it is still at work. Squash merges leave
# the branch out of main's history, so `git branch --merged` cannot say.
# Otherwise the worktree, branch and sessions all stay, and the comment says
# why.
#
# The worktree goes first, by git, before `claude rm` sees the sessions.
# `claude rm` removes only a worktree it recorded making (`claude --bg -w`),
# and these sessions were started inside one this script made, so it leaves
# them be; with the directory already gone, it has nothing to decide about,
# however many sessions shared it.
land_one() {
  local f=$1 id ident repo wt branch number url sha i completed tip sessions busy dirty out keep="" s n note="" done_text
  local -a removed=()
  id=$(jq -r .id "$f")
  ident=$(jq -r .ident "$f")
  repo=$(jq -r .repo "$f")
  wt=$(jq -r .worktree "$f")
  branch=$(jq -r .branch "$f")
  number=$(jq -r .merged.number "$f")
  url=$(jq -r .merged.url "$f")
  sha=$(jq -r .merged.sha "$f")

  i=$(issue "$id")
  # Moved on since tidy asked: the next run looks again. In work mode Linear's
  # GitHub integration has completed it already, which is what tidy saw.
  if [[ $mode == work ]]; then
    [[ $(jq -r .state.type <<<"$i") == completed ]] || return 0
    completed=$(jq -r .state.name <<<"$i")
  else
    [[ $(jq -r .state.name <<<"$i") == "$READY" ]] || return 0
    completed=$(jq -r '[.team.states.nodes[] | select(.type == "completed")] | sort_by(.position) | first | .name // empty' <<<"$i")
    [[ -n $completed ]] || die "$ident's team has no completed state"
  fi

  tip=$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch^{commit}" || true)
  # Every session in the worktree, by name or not: a resume that started a
  # copy leaves two.
  if ! sessions=$(cl agents --json --all </dev/null 2>/dev/null |
    jq -c --arg wt "$wt" '[.[] | select(.cwd == $wt) | {id, state}]'); then
    keep="Claude's sessions could not be listed."
  elif [[ -n $tip && $tip != "$sha" ]]; then
    keep="\`$branch\` is at ${tip:0:12}, and the PR merged ${sha:0:12}."
  elif busy=$(jq -r --arg ended "$ENDED" 'map(select(.state | IN($ended | split(" ")[]) | not)
    | "\(.id) is \(.state)") | join(", ")' <<<"$sessions") && [[ -n $busy ]]; then
    keep="a session there is still at work: $busy."
  elif [[ -d $wt ]]; then
    if [[ -z $tip || $(git -C "$wt" symbolic-ref --quiet HEAD || true) != "refs/heads/$branch" ]]; then
      keep="it is no longer on \`$branch\`."
    elif ! dirty=$(git -C "$wt" status --porcelain --untracked-files=all 2>&1) ||
      ! dirty=$(after_setup "$f" "$dirty") ||
      [[ -n $dirty ]]; then
      keep="it has changes not committed:
\`\`\`
$(head -n 10 <<<"$dirty")
\`\`\`"
    # --force for what setup left, which git would otherwise refuse to
    # remove along with the worktree. Nothing else is uncommitted by now.
    elif ! out=$(git -C "$repo" worktree remove --force "$wt" 2>&1); then
      keep="git would not remove it: $out"
    else
      removed+=("its worktree")
    fi
  else
    # Gone already, Nick's doing: drop git's record of it, or the branch
    # counts as checked out there and cannot be deleted.
    git -C "$repo" worktree prune
  fi

  if [[ -z $keep ]]; then
    n=0
    for s in $(jq -r '.[].id' <<<"$sessions"); do
      if cl rm "$s" </dev/null >/dev/null 2>&1; then
        n=$((n + 1))
      else
        note+=" \`claude rm $s\` failed."
      fi
    done
    # Work mode's sandbox for the sessions just removed (forget keeps it).
    rm -f "$state_dir/$ident.settings"
    if ((n == 1)); then
      removed+=("the agent's session")
    elif ((n > 1)); then
      removed+=("the agent's $n sessions")
    fi
    if [[ -n $tip ]] && ! out=$(git -C "$repo" branch -D "$branch" 2>&1); then
      note+=" Deleting \`$branch\` failed: $out"
    else
      [[ -z $tip ]] || removed+=("the branch \`$branch\`")
      # branch -D drops its section too, unless something already took the
      # branch and left the section behind.
      git -C "$repo" config --remove-section "branch.$branch" 2>/dev/null || true
    fi
    case ${#removed[@]} in
      0) done_text="Nothing of the agent's was left to remove." ;;
      1) done_text="Removed ${removed[0]}." ;;
      2) done_text="Removed ${removed[0]} and ${removed[1]}." ;;
      *) done_text="Removed ${removed[0]}, ${removed[1]} and ${removed[2]}." ;;
    esac
    done_text="Merged in [#$number]($url). $done_text$note"
  else
    done_text="Merged in [#$number]($url). Kept its worktree \`$wt\`, the branch and the agent's session, since $keep"
  fi
  # No push: Nick merged it himself. In work mode nothing goes to the issue,
  # which teammates read and which is in its completed state already; the
  # log has what was removed or kept.
  if [[ $mode == work ]]; then
    echo "night-shift: $ident: $done_text"
    if [[ -n $keep ]]; then
      # The session kept may still be attached to or resumed, with the
      # settings it was started with, so they stay; status lists them.
      [[ ! -f $state_dir/$ident.settings ]] ||
        echo "night-shift: $ident: its sandbox settings stay at $state_dir/$ident.settings until the session goes"
      notify "Night shift" "$ident: merged, worktree kept" || true
    fi
    forget "$f" "merged in #$number"
    return 0
  fi
  comment "$i" "$done_text"
  move "$i" "$completed"
  forget "$f" "merged in #$number, moved to $completed"
}

# Forgets waiting issues Nick has closed, with their issue text and archived
# results in the repo's .git/night-shift/. Their worktrees stay for `claude rm`
# or git's cleanup, since one may hold work not yet published. Only an answer
# from Linear counts: offline, nothing is forgotten. An issue in Handoff ready
# whose PR has merged is handed to land_one instead.
#
# One request per 50 waiting issues, Linear's default page, so each answer is
# whole and an issue missing from it does not exist. includeArchived matches
# what issue() finds by id, so an issue archived while waiting is judged by its
# state, not dropped as missing.
#
# GitHub allows 60 requests an hour without a token, for every caller on
# forge's address, so it is asked once a run for each issue in Handoff ready
# and no more, the longest unasked first, and not again in a run it refuses.
#
# In work mode, work_tidy_one decides for each issue Linear still has, and
# refused issues are asked about too, so one that closes is forgotten.
tidy() {
  local states=("$state_dir"/*.json) chunk nodes id f i gh=1 slug pr rc
  ((${#states[@]})) || return 0
  while read -r chunk; do
    # shellcheck disable=SC2016 # GraphQL's variables, not the shell's
    nodes=$(gql 'query($ids: [ID!]!) { issues(first: 50, includeArchived: true, filter: {id: {in: $ids}}) { nodes { id state { name type } } } }' \
      "$(jq -c '{ids: map(.id)}' <<<"$chunk")" | jq -c '.issues.nodes') || continue
    while IFS=$'\t' read -r id f; do
      i=$(jq -c --arg id "$id" '.[] | select(.id == $id)' <<<"$nodes")
      if [[ $mode == work && -n $i ]]; then
        work_tidy_one "$i" "$f"
        continue
      fi
      if [[ -z $i ]] || closed "$i"; then
        forget "$f"
        continue
      fi
      ((gh)) && [[ $(jq -r .state.name <<<"$i") == "$READY" ]] || continue
      slug=$(github_repo "$(jq -r .repo "$f")")
      [[ -n $slug ]] || continue
      # shellcheck disable=SC2016 # jq's variables, not the shell's
      update "$f" '.checked = $now' --arg now "$(now)"
      rc=0
      pr=$(merged_pr "$slug" "$(jq -r .branch "$f")") || rc=$?
      if ((rc == 2)); then
        echo "night-shift: GitHub refused, likely its hourly limit; merged PRs are looked for next run" >&2
        gh=0
      elif ((rc != 0)); then
        echo "night-shift: GitHub did not answer for $(basename "$f" .json)" >&2
      elif [[ -n $pr ]]; then
        # shellcheck disable=SC2016 # jq's variables, not the shell's
        update "$f" '.merged = $pr' --argjson pr "$pr"
        child _land "$viewer" "$f" </dev/null
      fi
    done < <(jq -r '.[] | [.id, .file] | @tsv' <<<"$chunk")
  done < <(jq -nc --arg mode "$mode" '[inputs | select(.phase == "waiting" or ($mode == "work" and .phase == "refused"))
    | {id, checked, file: input_filename}]
    | sort_by(.checked // "") | range(0; length; 50) as $n | .[$n:$n + 50]' "${states[@]}")
}

running() {
  local states=("$state_dir"/*.json)
  if ((${#states[@]})); then
    jq -s '[.[] | select(.phase == "running")] | length' "${states[@]}"
  else
    echo 0
  fi
}

# Each issue is handled in a process of its own, so one that fails, a deleted
# issue or a repo that will not fetch, costs that issue a warning and not the
# whole run. They stay in the unit, so stopping it ends them with the run, and
# hold the lock until then. Only claude leaves (cl).
child() {
  "$BASH" -euo pipefail "$0" "$@" || echo "night-shift: $1 ${*: -1} failed; next run tries again" >&2
}

run() {
  local f queued id
  for f in "$state_dir"/*.json; do
    child _finish "$viewer" "$f"
  done
  tidy
  if [[ $mode == work ]]; then
    work_queue
    return 0
  fi
  # shellcheck disable=SC2016 # GraphQL's variables, not the shell's
  queued=$(gql 'query($s: String!) { issues(first: 50, filter: {state: {name: {eq: $s}}}) { nodes { id priority createdAt } } }' \
    "$(jq -nc --arg s "$QUEUED" '{s: $s}')" |
    jq -r '.issues.nodes | sort_by((if .priority == 0 then 5 else .priority end), .createdAt) | .[].id')
  for id in $queued; do
    (($(running) < max)) || break
    child _start "$viewer" "$id"
  done
  backlog || echo "night-shift: backlog.md not written; the next run tries again" >&2
}

# --- Work mode ------------------------------------------------------------------
#
# On a Mac at work (home/night-shift.nix), against a Linear team Nick shares,
# whose workflow and labels are not his to change and whose issues his
# teammates read. What takes the place of forge's states:
#
#   Queued         a label of Nick's (the config's `label`) on an issue
#                  assigned to him, taken only if he added it himself and
#                  nobody else has changed the title or description since. A
#                  teammate writes the issue; adding the label is Nick saying
#                  the text is his task.
#   Running        moved to the team's started state (`startedState`), the one
#                  thing this writes to Linear.
#   Handoff ready, Needs you
#                  a notification and $state_dir/<ID>.report.md, which
#                  `night-shift status` shows. Nothing on the issue.
#   Done           Linear's GitHub integration completes the issue when the PR
#                  merges. tidy sees that, gh confirms the merge, and land_one
#                  cleans up as on forge.
#
# Nick resumes an agent here, with `night-shift resume <ID> <answer>`, or by
# adding the label again. Each team's repository, branch name, setup commands
# and checks come from NIGHT_SHIFT_CONFIG, a file of Nick's outside the repo,
# since this one is public: docs/night-shift.md, "On a Mac", has its shape.
#
# Each agent runs in Claude Code's sandbox, which the Mac's own sessions do
# not have, from NIGHT_SHIFT_SETTINGS (home/night-shift.nix). Its worktree is
# set up first, outside that sandbox, from origin's HEAD: what setup fetches
# needs Nick's credentials, LFS objects say, and nothing of the agent's is
# there yet to run.

LABEL="agent"
STARTED="In Progress"
config="{}"

load_config() {
  local extra
  [[ -r ${NIGHT_SHIFT_CONFIG:-} ]] ||
    die "no config at '${NIGHT_SHIFT_CONFIG:-}'; docs/night-shift.md, \"On a Mac\", has its shape"
  config=$(jq -ce 'if type == "object" then . else error("not an object") end' "$NIGHT_SHIFT_CONFIG") ||
    die "$NIGHT_SHIFT_CONFIG is not a JSON object"
  LABEL=$(jq -r --arg d "$LABEL" '.label // $d' <<<"$config")
  STARTED=$(jq -r --arg d "$STARTED" '.startedState // $d' <<<"$config")
  max=$(jq -r --arg d "$max" '.max // $d' <<<"$config")
  stall_hours=$(jq -r --arg d "$stall_hours" '.stallHours // $d' <<<"$config")
  [[ $max =~ ^[0-9]+$ && $stall_hours =~ ^[0-9]+$ ]] || die "max and stallHours in $NIGHT_SHIFT_CONFIG are whole numbers"
  # Where setup and the agents find the repos' own tools, a language's
  # package manager say, which launchd's PATH does not carry.
  extra=$(jq -r --arg h "$HOME" '(.path // []) | map(sub("^~"; $h)) | join(":")' <<<"$config")
  [[ -z $extra ]] || PATH=$extra:$PATH
}

# work_labelled <issue json>: the history entry that last added Nick's label
# to the issue, or its creation, for a label set when the issue was made.
# Nothing when the issue does not carry the label. A creation counts as
# Nick's only if no integration made it: Linear leaves the creator empty for
# one acting as itself, and names the bot for one acting as him, and
# work_refusal refuses either.
work_labelled() {
  jq -c --arg l "$LABEL" '
    ([.labels.nodes[] | select(.name == $l) | .id] | first) as $id
    | select($id)
    | ([.history.nodes[] | select((.addedLabelIds // []) | index($id))] | max_by(.createdAt))
      // {createdAt, actorId: .creator.id, botActor}' <<<"$1"
}

# work_refusal <issue json> <labelled json>: why the issue is not taken, or
# nothing. An integration acting with Nick's login, the Linear MCP server in
# a Claude session say, could add the label as him; Linear records it as a
# bot's, which is refused.
work_refusal() {
  jq -r --arg me "$viewer" --argjson l "${2:-null}" '
    if (.assignee.id // "") != $me then "it is not assigned to you"
    elif .history.pageInfo.hasNextPage then "its history is too long to tell who added the label"
    elif $l == null then "it does not carry the label"
    elif $l.actorId != $me or $l.botActor != null then "the label was last added by someone else or by an integration"
    elif [.history.nodes[] | select(.createdAt > $l.createdAt and .actorId != $me
        and (.updatedDescription == true or .fromTitle != null))] != []
    then "someone else changed its title or description after you added the label"
    else empty end' <<<"$1"
}

# work_refuse <issue json> <labelled json> <why>: not taken, and said once.
# The state file remembers which labelling was refused, so later runs stay
# quiet until the label is added again.
work_refuse() {
  local ident
  ident=$(jq -r .identifier <<<"$1")
  jq -n --arg id "$(jq -r .id <<<"$1")" --arg ident "$ident" --arg at "$(jq -r '.createdAt // ""' <<<"${2:-null}")" \
    --arg seen "$(jq -r '.updatedAt // ""' <<<"$1")" \
    '{id: $id, ident: $ident, phase: "refused", labelled: $at, seen: $seen}' >"$state_dir/$ident.json"
  stop_issue "$1" "Not started" "Not started: $3. Add the label again to try again." "Not started"
}

# work_seen <issue json> <state file>: the issue looked at and left as it
# was. work_queue asks Linear for it again only once it has changed since.
work_seen() {
  # shellcheck disable=SC2016 # jq's variables, not the shell's
  update "$2" '.seen = $u' --arg u "$(jq -r '.updatedAt // ""' <<<"$1")"
}

# work_discard <repo> <worktree> <branch> <ident>: undoes a start that ended
# before an agent ran.
work_discard() {
  git -C "$1" worktree remove --force "$2" >/dev/null 2>&1 || true
  git -C "$1" branch -D "$3" >/dev/null 2>&1 || true
  rm -f "$state_dir/$4.settings"
}

# work_repo_dir <repo conf>: the checkout a repository's entry in the config
# names, with ~ for $HOME, or nothing.
work_repo_dir() {
  jq -r --arg h "$HOME" '(.dir // "") | sub("^~"; $h)' <<<"${1:-null}"
}

# work_settings_files <repo> <dir>: the settings files a session in <dir>, a
# checkout or worktree of <repo>, reads below --settings, one per line: the
# user's, the main checkout's two, and the branch's settings.json. Both
# work_overrides and work_settings go by this list.
work_settings_files() {
  printf '%s\n' "$HOME/.claude/settings.json" "$1/.claude/settings.json" "$1/.claude/settings.local.json" \
    "$2/.claude/settings.json"
}

# work_overrides <repo> <worktree>: settings files that would change the
# agent's sandbox, or run a command outside it. --settings outranks the
# project's scalars, but lists such as excludedCommands or allowWrite add up
# across scopes, and a key it leaves unset is taken from below. A worktree's
# session reads the main checkout's settings.local.json as well as the
# branch's own settings.json.
#
# The sandbox covers commands only. Claude runs a helper command itself, with
# Nick's full access, in a worktree the agent writes, so a repository's is
# refused too; Nick's own, in his user settings, are his to run. Hooks, the
# status line and file suggestions are off (disableAllHooks in
# home/night-shift.nix), and plugins, whose LSP servers and monitors also run
# outside the sandbox, are turned off by work_settings.
work_overrides() {
  local s keys
  while IFS= read -r s; do
    keys='["sandbox", "apiKeyHelper", "awsAuthRefresh", "awsCredentialExport", "gcpAuthRefresh",
      "otelHeadersHelper", "subagentStatusLine"]'
    [[ $s != "$HOME/.claude/settings.json" ]] || keys='["sandbox"]'
    [[ -f $s ]] && jq -e --argjson k "$keys" 'any(keys[]; IN($k[]))' "$s" >/dev/null 2>&1 && echo "$s"
  done < <(work_settings_files "$1" "$2")
  return 0
}

# work_bootstrap <repo conf> <worktree> <log>: the repo's setup commands, in
# the new worktree, outside the sandbox, each with half an hour to finish.
# Without the run lock's descriptor, which a daemon one of them starts, a
# build server say, would otherwise hold for as long as it runs.
work_bootstrap() {
  local cmd
  : >"$3"
  while IFS= read -r cmd; do
    [[ -n $cmd ]] || continue
    printf '$ %s\n' "$cmd" >>"$3"
    (cd "$2" && timeout 1800 "$BASH" -c "$cmd") </dev/null >>"$3" 2>&1 9>&- || return 1
  done < <(jq -r '(.bootstrap // [])[]' <<<"$1")
}

# work_settings <repo conf> <out> <dir> <repo>: a session's settings in
# <dir>, a checkout or worktree of <repo>: Nix's base plus the repo's
# additions from the config, which can only add: hosts to reach, paths to
# write or to hide, binding to localhost (a test server), environment,
# though not over a variable the base sets. Written outside the checkout,
# where commands in the sandbox cannot change it, and given with --settings.
#
# Every plugin a scope enables is turned off, except those the base enables:
# a plugin's LSP servers and monitors run outside the sandbox, in a checkout
# the session writes, and a language server loads code from it (a
# workspace's own TypeScript, say). Enabled plugins merge per plugin, the
# highest scope that names one deciding, so each needs naming here.
work_settings() {
  local s files=() plugins
  [[ -r ${NIGHT_SHIFT_SETTINGS:-} ]] || return 1
  # And the checkout's own settings.local.json, which work_overrides leaves
  # out: in an agent's worktree it is the dispatcher's (work_local_settings).
  while IFS= read -r s; do
    [[ ! -f $s ]] || files+=("$s")
  done < <(work_settings_files "$4" "$3" && echo "$3/.claude/settings.local.json")
  plugins=$(jq -nc '[inputs | (.enabledPlugins // {}) | keys[]] | unique' /dev/null "${files[@]}") || return 1
  jq --argjson x "$(jq -c '.sandbox // {}' <<<"$1")" --argjson p "$plugins" '
    .sandbox.network.allowedDomains += ($x.allowedDomains // [])
    | .sandbox.filesystem.allowWrite += ($x.allowWrite // [])
    | .sandbox.filesystem.denyRead += ($x.denyRead // [])
    | if $x.allowLocalBinding == true then .sandbox.network.allowLocalBinding = true else . end
    | .env = ($x.env // {}) + .env
    | .enabledPlugins = (reduce $p[] as $n ({}; .[$n] = false)) + (.enabledPlugins // {})' \
    "$NIGHT_SHIFT_SETTINGS" >"$2"
}

# work_local_settings <settings> <worktree>: the sandbox, environment, deny
# rules and what turns hooks and plugins off, from an agent's settings, in
# its worktree's .claude/settings.local.json, which commands in the sandbox
# cannot write. A session claude starts there without --settings, a copy
# from a resume say, is contained all the same.
work_local_settings() {
  mkdir -p "$2/.claude"
  jq '{sandbox, env, disableAllHooks, enabledPlugins, permissions: {deny: .permissions.deny}}' "$1" \
    >"$2/.claude/settings.local.json"
}

# work_safe [claude args...]: an interactive Claude session here, in the
# agents' sandbox (`cld-safe`), with the repository's additions from the
# config when this is in a repository it names. Refused, as an agent's
# start is, when the repository's settings would change the sandbox or run
# a command outside it. Nothing is written in the checkout, whose
# settings.local.json is Nick's, and the settings go when the session ends.
work_safe() {
  local top repo common c dir conf="{}" overrides settings rc=0
  top=$(git rev-parse --show-toplevel 2>/dev/null) || top=$PWD
  repo=$top
  # A worktree's main checkout, whose settings its sessions read too.
  if common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && [[ $common == */.git ]]; then
    repo=${common%/.git}
  fi
  if [[ -r ${NIGHT_SHIFT_CONFIG:-} ]]; then
    load_config
    while IFS= read -r c; do
      dir=$(work_repo_dir "$c")
      if [[ -n $dir && $(realpath -m -- "$dir") == "$(realpath -m -- "$repo")" ]]; then
        conf=$c
        break
      fi
    done < <(jq -c '.repos // {} | .[]' <<<"$config")
  fi
  overrides=$(work_overrides "$repo" "$top")
  [[ -z $overrides ]] ||
    die "these settings would change the sandbox or run a command outside it: $(paste -sd ' ' <<<"$overrides")"
  mkdir -p "$state_dir"
  # Not *.json or *.settings, the state files' and kept sessions' globs.
  settings=$(mktemp "$state_dir/safe.XXXXXX")
  # Expanded now: the local is gone by the time the trap runs.
  # shellcheck disable=SC2064
  trap "rm -f $(printf '%q' "$settings")" EXIT
  work_settings "$conf" "$settings" "$top" "$repo" ||
    die "the settings could not be written: '${NIGHT_SHIFT_SETTINGS:-}' is missing, or a Claude settings file here is not JSON"
  claude --settings "$settings" --strict-mcp-config "$@" || rc=$?
  return "$rc"
}

work_prompt_new() {
  local issue=$1 repo=$2 wt=$3 branch=$4 base=$5 result=$6 conf=$7
  cat <<EOP
You are the night shift: an unattended Claude Code session working on a task
Nick queued in Linear at work. Nobody is watching. He reads what you leave
when he is next at his desk.

$(prompt_task "$issue")

## How to work

- You are in a git worktree of $(basename "$repo") at $wt, on branch $branch,
  made from $base, with its dependencies installed. Read the repository's
  CLAUDE.md first. Where it and this prompt disagree, CLAUDE.md wins, except
  that you never push, merge or deploy, and you keep the branch's name.
$PROMPT_SCOPE
- The task above is all you have of the issue: you have no Linear access and
  no MCP servers. ${result%.md}.issue.md has the same text.
- Your commands run in a sandbox. The network reaches GitHub and package
  registries, without credentials. There is no docker. Do not look for a way
  around it; if the task needs more, stop and say what.
- Checks: $(jq -r '.checks // "the ones the repository names that need no running services"' <<<"$conf").
  Do not run docker, docker compose, database migrations, or anything that
  needs running services. If verifying the change needs them, finish what
  you can and stop as blocked, saying what is left to verify.
- Commit on this branch, following the repository's conventions for commit
  messages and PR titles, then write the PR handoff with the core plugin's
  pr-handoff skill, so Nick can publish it with \`pr-handoff\` from this
  worktree. Touch no other worktree.
$PROMPT_STOP

$(prompt_finish "$result")

Nick answers on this machine, and you will be resumed in this session with
his answer, so do not wait for one here.
EOP
}

# The answer from `night-shift resume`, read by work_start_one before the file
# goes, or nothing when the label was added again instead.
work_answer=""

work_prompt_resume() {
  local issue=$1 since=$2 result=$3 new lead="by adding its label again, with no answer here."
  new=$(answers "$issue" "$since")
  [[ -z $work_answer ]] || lead="with this answer:"
  cat <<EOP
Nick resumed $(jq -r .identifier <<<"$issue"), $lead
${work_answer:+
$work_answer
}${new:+
His comments on the issue since you last heard from him:

$new
}
Carry on under the same rules. When you finish or stop again, write $result
the same way, and end your turn.
EOP
}

# One issue assigned to Nick with his label: start an agent on it, resume the
# one it had, or say why not, once.
work_start_one() {
  local id=$1 i ident f l why conf repo fb base sha name wt branch slugged settings result session="" overrides setup
  i=$(issue "$id")
  ! closed "$i" || return 0
  ident=$(jq -r .identifier <<<"$i")
  f=$state_dir/$ident.json
  l=$(work_labelled "$i")

  if [[ -f $f ]]; then
    case $(jq -r .phase "$f") in
      running) return 0 ;;
      waiting)
        if [[ -f $state_dir/$ident.answer ]]; then
          work_answer=$(<"$state_dir/$ident.answer")
          rm "$state_dir/$ident.answer"
        elif [[ -z $l || ! $(jq -r .createdAt <<<"$l") > $(jq -r .since "$f") || -n $(work_refusal "$i" "$l") ]]; then
          work_seen "$i" "$f"
          return 0
        fi
        # Either way its trigger is spent, so a resume that fails is said
        # once, not every run.
        # shellcheck disable=SC2016 # jq's variables, not the shell's
        if resume_agent "$i" "$f" work_prompt_resume; then
          update "$f" 'del(.seen)'
        else
          update "$f" '.since = $now' --arg now "$(now)"
        fi
        return 0
        ;;
      refused)
        if [[ -z $l || ! $(jq -r .createdAt <<<"$l") > $(jq -r '.labelled // ""' "$f") ]]; then
          work_seen "$i" "$f"
          return 0
        fi
        rm "$f"
        ;;
    esac
  fi

  why=$(work_refusal "$i" "$l")
  [[ -z $why ]] || {
    work_refuse "$i" "$l" "$why"
    return 0
  }
  conf=$(jq -c --arg k "$(jq -r .team.key <<<"$i")" '.repos[$k] // empty' <<<"$config")
  repo=$(work_repo_dir "$conf")
  if [[ -z $repo ]] || ! git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    work_refuse "$i" "$l" "no repository with an \`origin\` is set for team $(jq -r .team.key <<<"$i") in $NIGHT_SHIFT_CONFIG"
    return 0
  fi
  # Not <ID>.json or any *.json: that is the state files' glob.
  settings=$state_dir/$ident.settings
  if [[ ! -r ${NIGHT_SHIFT_SETTINGS:-} ]]; then
    work_refuse "$i" "$l" "the sandbox settings at '${NIGHT_SHIFT_SETTINGS:-}' are missing, so no agent starts; \`hms\` writes them"
    return 0
  fi
  # Offline, or the SSH agent locked: left for the next run.
  fb=$(fetch_base "$repo") || die "$ident: could not fetch $(basename "$repo"); trying again next run"
  read -r base sha <<<"$fb"
  base=origin/$base
  slugged=$(jq -r .title <<<"$i" | slug)
  name="${ident,,}-$slugged"
  wt=$repo/.claude/worktrees/$name
  # The identifier in the branch is what links the PR to the issue.
  branch=$(jq -r --arg ID "$ident" --arg id "${ident,,}" --arg slug "$slugged" \
    '(.branch // "night-shift/{id}-{slug}") | gsub("\\{ID\\}"; $ID) | gsub("\\{id\\}"; $id) | gsub("\\{slug\\}"; $slug)' <<<"$conf")
  if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
    work_refuse "$i" "$l" "the branch template gives \`$branch\`, which is not a branch name"
    return 0
  fi
  if ! add_worktree "$repo" "$branch" "$wt" "$sha"; then
    work_refuse "$i" "$l" "could not make the worktree \`$wt\` on \`$branch\`. One may be left from an earlier run"
    return 0
  fi
  # No agent has run in the worktree yet, so on any refusal from here it
  # goes, with its branch, and adding the label again starts afresh.
  overrides=$(work_overrides "$repo" "$wt")
  if [[ -n $overrides ]]; then
    work_discard "$repo" "$wt" "$branch" "$ident"
    work_refuse "$i" "$l" "these settings would change the agent's sandbox or run a command outside it: $(paste -sd ' ' <<<"$overrides")"
    return 0
  fi
  if ! work_bootstrap "$conf" "$wt" "$state_dir/$ident.bootstrap.log"; then
    work_discard "$repo" "$wt" "$branch" "$ident"
    work_refuse "$i" "$l" "setting up the worktree failed, and it is removed. \`$state_dir/$ident.bootstrap.log\` says why"
    return 0
  fi
  if ! work_settings "$conf" "$settings" "$wt" "$repo" || ! work_local_settings "$settings" "$wt"; then
    work_discard "$repo" "$wt" "$branch" "$ident"
    work_refuse "$i" "$l" "the agent's settings could not be written: the repository's \`sandbox\` in $NIGHT_SHIFT_CONFIG does not fit them, or a Claude settings file is not JSON. The worktree is removed"
    return 0
  fi
  # The files setup left untracked, before the agent has written anything, for
  # land_one to tell from the agent's work (after_setup). Not tracked files
  # setup changed: the agent may change one of those too, a lockfile say, and
  # its line would read the same.
  setup=$(git -C "$wt" status --porcelain --untracked-files=all | grep '^?? ' || true)
  result=$(result_path "$repo" "$ident")
  write_issue "$i" "$result"
  # No MCP servers: the repo's own include Linear's, through which a session
  # acting as Nick could add the label to an issue and queue it.
  if ! (cd "$wt" && cl --bg -n "$name" --settings "$settings" --strict-mcp-config --permission-mode auto </dev/null \
    "$(work_prompt_new "$i" "$repo" "$wt" "$branch" "$base" "$result" "$conf")") >/dev/null; then
    work_discard "$repo" "$wt" "$branch" "$ident"
    work_refuse "$i" "$l" "\`claude --bg\` failed, and the worktree is removed"
    return 0
  fi
  read -r _ session _ <<<"$(agent "$name" "$wt")" || true
  jq -n --arg id "$id" --arg ident "$ident" --arg repo "$repo" --arg worktree "$wt" \
    --arg branch "$branch" --arg name "$name" --arg session "$session" --arg now "$(now)" \
    --arg labelled "$(jq -r .createdAt <<<"$l")" --arg setup "$setup" \
    '{id: $id, ident: $ident, repo: $repo, worktree: $worktree, branch: $branch, name: $name,
      session: $session, phase: "running", started: $now, since: $now, labelled: $labelled,
      setup: ($setup | split("\n") | map(select(. != "")))}' >"$f.tmp"
  mv "$f.tmp" "$f"
  [[ $(jq -r .state.name <<<"$i") == "$STARTED" ]] || move "$i" "$STARTED"
  echo "night-shift: started $ident"
}

# work_queue: what run starts in work mode. Answers left with `night-shift
# resume` first, since Nick is waiting on those, then the issues assigned to
# him with his label, highest priority first. Passed over: those with an
# agent at work, and those waiting or refused that have not changed in Linear
# since work_start_one last looked (work_seen), which a label added again or a
# new comment would. work_start_one decides the rest.
work_queue() {
  local f ident states=("$state_dir"/*.json) known="[]" queued id
  for f in "$state_dir"/*.answer; do
    (($(running) < max)) || return 0
    ident=$(basename "$f" .answer)
    if [[ -f $state_dir/$ident.json ]]; then
      child _start "$viewer" "$(jq -r .id "$state_dir/$ident.json")"
    else
      rm -f "$f"
    fi
  done
  ((${#states[@]} == 0)) || known=$(jq -sc . "${states[@]}")
  # shellcheck disable=SC2016 # GraphQL's variables, not the shell's
  queued=$(gql 'query($l: String!) { issues(first: 50, filter: {assignee: {isMe: {eq: true}},
      labels: {some: {name: {eq: $l}}}, state: {type: {nin: ["completed", "canceled"]}}}) {
      nodes { id priority createdAt updatedAt } } }' "$(jq -nc --arg l "$LABEL" '{l: $l}')" |
    jq -r --argjson known "$known" '
      ($known | map({key: .id, value: .}) | from_entries) as $f
      | .issues.nodes | sort_by((if .priority == 0 then 5 else .priority end), .createdAt) | .[]
      | select($f[.id] as $s | $s == null
          or ($s.phase == "waiting" and .updatedAt > ($s.seen // $s.since))
          or ($s.phase == "refused" and .updatedAt > ($s.seen // "")))
      | .id')
  for id in $queued; do
    (($(running) < max)) || break
    child _start "$viewer" "$id"
  done
}

# merged_pr_gh <owner/name> <branch>: merged_pr's answer, from gh, for a
# private repository, which GitHub answers only with a token. Read-only, and
# here, outside the sandbox, is the one place that has Nick's login.
merged_pr_gh() {
  gh pr list --repo "$1" --head "$2" --state merged --json number,url,headRefOid </dev/null |
    jq -c 'max_by(.number) | select(.) | {number, url, sha: .headRefOid}'
}

# work_tidy_one <issue json> <state file>: tidy for one issue in work mode. A
# canceled issue is forgotten. A completed one that waited for Nick is
# landed when gh finds the merged PR from its branch, and forgotten otherwise,
# its worktree kept, as forge does with an issue closed by hand.
work_tidy_one() {
  local i=$1 f=$2 slug pr rc=0
  case $(jq -r .state.type <<<"$i") in
    canceled)
      forget "$f"
      return 0
      ;;
    completed) ;;
    *) return 0 ;;
  esac
  if [[ $(jq -r .phase "$f") != waiting ]]; then
    forget "$f" "completed"
    return 0
  fi
  slug=$(github_repo "$(jq -r .repo "$f")")
  [[ -z $slug ]] || pr=$(merged_pr_gh "$slug" "$(jq -r .branch "$f")") || rc=$?
  if ((rc != 0)); then
    echo "night-shift: gh could not say whether $(jq -r .ident "$f") merged; the next run asks again" >&2
  elif [[ -n ${pr:-} ]]; then
    # shellcheck disable=SC2016 # jq's variables, not the shell's
    update "$f" '.merged = $pr' --argjson pr "$pr"
    child _land "$viewer" "$f" </dev/null
  else
    forget "$f" "completed with no merged PR from its branch; its worktree stays"
  fi
}

work_check() {
  local data k conf dir s
  # shellcheck disable=SC2016 # GraphQL's variables, not the shell's
  data=$(gql 'query($l: String!) { viewer { id displayName }
    teams { nodes { key states { nodes { name } } } }
    issueLabels(first: 50, filter: {name: {eq: $l}}) { nodes { name } } }' "$(jq -nc --arg l "$LABEL" '{l: $l}')")
  echo "key: works, acting as $(jq -r .viewer.displayName <<<"$data")"
  if [[ $(jq '.issueLabels.nodes | length' <<<"$data") -gt 0 ]]; then
    echo "label $LABEL: exists"
  else
    echo "label $LABEL: not in Linear yet"
  fi
  while IFS= read -r k; do
    conf=$(jq -c --arg k "$k" '.repos[$k]' <<<"$config")
    dir=$(work_repo_dir "$conf")
    jq -r --arg k "$k" --arg s "$STARTED" '[.teams.nodes[] | select(.key == $k)] | first
      | if . == null then "team \($k): not found"
        elif any(.states.nodes[]; .name == $s) then "team \($k): has \($s)"
        else "team \($k): no state \($s)" end' <<<"$data"
    if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
      echo "team $k: repository $dir"
    else
      echo "team $k: no repository with an origin at '$dir'"
    fi
    # claude --bg refuses a directory whose trust prompt was never accepted.
    if [[ $(jq -r --arg d "$dir" '.projects[$d].hasTrustDialogAccepted // false' "$HOME/.claude.json" 2>/dev/null) == true ]]; then
      echo "team $k: Claude trusts it"
    else
      echo "team $k: run claude in $dir once and accept the trust prompt"
    fi
    for s in $(work_overrides "$dir" "$dir"); do
      echo "team $k: $s changes the sandbox or runs a command outside it, so its issues are refused"
    done
  done < <(jq -r '.repos // {} | keys[]' <<<"$config")
  # The fields a run asks for, on one issue of Nick's, so a field Linear has
  # renamed shows here rather than as a failed run.
  if gql "query { issues(first: 1, filter: {assignee: {isMe: {eq: true}}}) { nodes { $WORK_FIELDS } } }" >/dev/null; then
    echo "issue fields: all known to Linear"
  fi
  if jq -e '.sandbox.enabled and (.sandbox.filesystem.denyRead | index("~/Library/Keychains"))
      and .disableAllHooks == true and (.permissions.deny | index("WebFetch") and index("WebSearch"))' \
    "${NIGHT_SHIFT_SETTINGS:-/dev/null}" >/dev/null 2>&1; then
    echo "sandbox: on, with the keychain hidden, hooks off and no web tools"
  else
    echo "sandbox: '${NIGHT_SHIFT_SETTINGS:-}' is missing, does not hide ~/Library/Keychains, leaves hooks on, or allows web tools"
  fi
  if command -v claude >/dev/null; then
    echo "claude: $(claude --version </dev/null)"
  else
    echo "claude: not on PATH"
  fi
  if notify "Night shift" "A test notification from night-shift check"; then
    echo "notification: sent"
  fi
}

# Issue drafts, for `night-shift file`: <repo>/.git/linear-handoff/<any>.md,
# written by Claude or by hand, the way pr-handoff takes PR text. A front
# matter of `key: value` lines, no comments, then the description:
#
#   ---
#   title: forge: push to ntfy when night-shift runs keep failing
#   repo: nix-config        default: the repository the draft is in
#   priority: high          urgent, high, medium, low or none (default)
#   project: Night shift    default: none; must exist in the team
#   team: NNO               needed only with more than one team
#   ---
#
# Filed as Nick, an issue passes the dispatcher's "created by you" check, so
# each is shown and confirmed on its own, and its description ends with a line
# saying it was drafted, so its origin shows when he later queues it. It lands
# in the team's backlog, never in Queued: starting an agent stays his move.

DRAFT_KEYS=" title repo priority project team "

# draft_field <file> <key>: the value, less one pair of surrounding quotes.
draft_field() {
  awk -v k="$2" '
    NR == 1 { next }
    $0 == "---" { exit }
    { i = index($0, ":"); if (i && substr($0, 1, i - 1) == k) {
        v = substr($0, i + 1); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
        if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
        print v; exit } }' "$1"
}

# draft_body <file>: everything after the front matter, less leading blanks.
draft_body() {
  awk 'NR == 1 { next }
    !body && $0 == "---" { body = 1; next }
    body { if (NF || seen) { seen = 1; print } }' "$1"
}

# draft_problem <file>: why the draft cannot be filed, or nothing. The text is
# shown to Nick and becomes an agent's task, so anything that could make what
# he reads differ from what is filed is refused: invalid UTF-8, control
# characters other than tab and newline, and invisible format characters.
draft_problem() {
  local f=$1 k
  if [[ -L $f || ! -f $f ]]; then
    echo "not a regular file"
  elif LC_ALL=C.UTF-8 grep -qaxv '.*' "$f"; then
    echo "not valid UTF-8"
  elif LC_ALL=C.UTF-8 grep -qP '[\x{0}-\x{8}\x{B}-\x{1F}\x{7F}-\x{9F}\p{Cf}\p{Zl}\p{Zp}]' "$f"; then
    echo "contains control or invisible characters"
  elif [[ $(head -n 1 "$f") != --- ]] || [[ $(awk 'NR > 1 && $0 == "---"' "$f" | head -n 1) != --- ]]; then
    echo "front matter must open and close with ---"
  else
    while IFS= read -r k; do
      [[ -z $k || $DRAFT_KEYS == *" $k "* ]] || { echo "unknown key '$k'"; return; }
    done < <(awk 'NR == 1 { next } $0 == "---" { exit } NF { i = index($0, ":"); print (i ? substr($0, 1, i - 1) : $0) }' "$f")
  fi
}

# draft_input <file> <repo> <workspace json>: the IssueCreateInput and a line
# describing it, or why not.
draft_input() {
  local f=$1 problem title repo tkey team teamid priority project label state proj
  problem=$(draft_problem "$f")
  [[ -z $problem ]] || { echo "$problem"; return 1; }
  title=$(draft_field "$f" title)
  [[ -n $title ]] || { echo "no title"; return 1; }
  repo=$(draft_field "$f" repo)
  repo=${repo:-$2}
  tkey=$(draft_field "$f" team)
  if [[ -z $tkey ]]; then
    [[ $(jq '.teams.nodes | length' <<<"$3") -eq 1 ]] || { echo "more than one team; add team:"; return 1; }
    tkey=$(jq -r '.teams.nodes[0].key' <<<"$3")
  fi
  team=$(jq -c --arg k "$tkey" '.teams.nodes[] | select(.key == $k)' <<<"$3")
  [[ -n $team ]] || { echo "no team '$tkey'"; return 1; }
  teamid=$(jq -r .id <<<"$team")
  # Exactly one repo label of that name that this team can use: the
  # workspace's, or the team's own.
  label=$(jq -r --arg r "$repo" --arg t "$teamid" \
    '[.repo.nodes[] | select(.name == $r and (.team == null or .team.id == $t)) | .id] | if length == 1 then .[0] else empty end' <<<"$3")
  [[ -n $label ]] || { echo "no single repo label '$repo' for team $tkey"; return 1; }
  # The backlog, or failing that the first not-started state; never Queued.
  state=$(jq -c --arg q "$QUEUED" '[.states.nodes[] | select(.name != $q)] as $s
    | ([$s[] | select(.type == "backlog")] | sort_by(.position) | first)
      // ([$s[] | select(.type == "unstarted")] | sort_by(.position) | first) // empty' <<<"$team")
  [[ -n $state ]] || { echo "team $tkey has no backlog state"; return 1; }
  case $(draft_field "$f" priority) in
    urgent) priority=1 ;; high) priority=2 ;; medium) priority=3 ;; low) priority=4 ;;
    "" | none) priority=0 ;;
    *) echo "priority is urgent, high, medium, low or none"; return 1 ;;
  esac
  project=$(draft_field "$f" project)
  proj=""
  if [[ -n $project ]]; then
    proj=$(jq -r --arg p "$project" \
      '[.projects.nodes[] | select(.name == $p) | .id] | if length == 1 then .[0] else empty end' <<<"$team")
    [[ -n $proj ]] || { echo "no single project '$project' in team $tkey"; return 1; }
  fi
  jq -nc --arg team "$teamid" --arg title "$title" --arg body "$(draft_body "$f")" \
    --argjson priority "$priority" --arg label "$label" --argjson state "$state" \
    --arg proj "$proj" --arg key "$tkey" --arg repo "$repo" --arg project "$project" '
    {input: ({teamId: $team, title: $title, priority: $priority,
              description: "\($body)\n\n_Filed from a draft with `night-shift file`._",
              labelIds: [$label], stateId: $state.id}
             + (if $proj == "" then {} else {projectId: $proj} end)),
     shown: "\($key) · \($repo) · \(["no priority", "urgent", "high", "medium", "low"][$priority])\(if $project == "" then "" else " · \($project)" end) · into \($state.name)"}'
}

file_drafts() {
  local d dir common f data input n bad=0 answer out rc filing filed=0
  local -a drafts=() repos=() inputs=()
  local -A seen=()
  for d in "$projects"/*/; do
    git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || continue
    common=$(git -C "$d" rev-parse --path-format=absolute --git-common-dir)
    # A worktree checked out in ~/projects shares its repository's drafts.
    [[ -z ${seen[$common]:-} ]] || continue
    seen[$common]=1
    dir=$common/linear-handoff
    [[ -e $dir ]] || continue
    [[ -d $dir && ! -L $dir ]] || die "$dir is not a plain directory"
    for f in "$dir"/*.filing; do
      echo "night-shift: $f was being filed when a run was cut off; check Linear, then delete it or rename it back to .md" >&2
    done
    for f in "$dir"/*.md; do
      drafts+=("$f")
      repos+=("$(basename "$(dirname "$common")")")
    done
  done
  if ((${#drafts[@]} == 0)); then
    echo "no drafts in $projects/*/.git/linear-handoff/"
    return 0
  fi
  data=$(gql 'query { viewer { displayName }
    teams { nodes { id key states { nodes { id name type position } } projects(first: 100) { nodes { id name } } } }
    repo: issueLabels(first: 250, filter: {parent: {name: {eq: "repo"}}}) { nodes { id name team { id } } } }')

  # Every draft is checked before any is offered, so a mistake files nothing.
  for n in "${!drafts[@]}"; do
    if ! input=$(draft_input "${drafts[n]}" "${repos[n]}" "$data"); then
      echo "night-shift: ${drafts[n]}: $input" >&2
      bad=1
    fi
    inputs+=("$input")
  done
  ((bad == 0)) || die "nothing filed; fix the drafts above"

  echo "Filing as $(jq -r .viewer.displayName <<<"$data"), one draft at a time."
  for n in "${!drafts[@]}"; do
    f=${drafts[n]}
    printf '\n── %s (written %s)\n%s\n\n%s\n\n%s\n\n' "$f" "$(date -r "$f" '+%F %R')" \
      "$(jq -r .shown <<<"${inputs[n]}")" "$(jq -r .input.title <<<"${inputs[n]}")" \
      "$(jq -r .input.description <<<"${inputs[n]}")"
    printf 'File this one? [y/N] '
    read -r answer </dev/tty || answer=""
    [[ $answer == [yY] ]] || { echo "kept"; continue; }
    # Moved aside first: if Linear takes it but the answer is lost, a rerun
    # must not file it again.
    filing=${f%.md}.filing
    mv "$f" "$filing"
    rc=0
    # shellcheck disable=SC2016 # GraphQL's variables, not the shell's
    out=$(gql 'mutation($i: IssueCreateInput!) { issueCreate(input: $i) { success issue { identifier url } } }' \
      "$(jq -c '{i: .input}' <<<"${inputs[n]}")") || rc=$?
    if ((rc == 0)); then
      rm "$filing"
      jq -r '.issueCreate.issue | "filed \(.identifier)  \(.url)"' <<<"$out"
      filed=$((filed + 1))
    elif ((rc == 1)); then
      echo "night-shift: no answer from Linear, so it may be filed; check, then delete $filing or rename it back to .md" >&2
    else
      mv "$filing" "$f"
      echo "night-shift: Linear refused it; the draft is kept" >&2
    fi
  done
  echo "filed $filed of ${#drafts[@]}"
}

check() {
  local data teams
  data=$(gql 'query { viewer { id displayName }
    teams { nodes { key name states { nodes { name } } } }
    issueLabels(first: 250, filter: {parent: {name: {eq: "repo"}}}) { nodes { name } } }')
  echo "key: works, acting as $(jq -r .viewer.displayName <<<"$data")"
  teams=$(jq -c '.teams.nodes[]' <<<"$data")
  while IFS= read -r t; do
    jq -r --argjson want "$(jq -nc --arg a "$QUEUED" --arg b "$RUNNING" --arg c "$READY" --arg d "$NEEDS" '[$a, $b, $c, $d]')" '
      [.states.nodes[].name] as $have
      | "team \(.key): " + (if ($want - $have) == [] then "all four states"
        else "missing states: \(($want - $have) | join(", "))" end)' <<<"$t"
  done <<<"$teams"
  jq -r '.issueLabels.nodes[].name' <<<"$data" | while IFS= read -r label; do
    if git -C "$projects/$label" rev-parse --git-dir >/dev/null 2>&1; then
      echo "repo label $label: $projects/$label"
    else
      echo "repo label $label: no repository at $projects/$label"
    fi
  done
  [[ $(jq '.issueLabels.nodes | length' <<<"$data") -gt 0 ]] || echo "no labels in a 'repo' group yet"
  if command -v claude >/dev/null; then
    echo "claude: $(claude --version </dev/null)"
  else
    echo "claude: not on PATH"
  fi
  if [[ -r ${NIGHT_SHIFT_NTFY_FILE:-} ]]; then
    echo "ntfy: configured"
  else
    echo "ntfy: no topic, so no pushes"
  fi
}
# after_run: the unit's ExecStopPost, so it sees every way a run ends, a
# timeout or a kill included, in systemd's $SERVICE_RESULT. A run that cannot
# reach Linear fails without touching any issue, so without this a revoked key
# or a long outage is silence. One push once `failed_runs` runs in a row have
# failed, 20 minutes after the first at the timer's pace, so a Wi-Fi drop
# passes quietly, and no more until a run succeeds. A push that does not go
# out is tried again after the next failure. Runs started from a shell count
# neither way.
after_run() {
  local f=$state_dir/failed-runs n="" why where="journalctl --user -u night-shift on forge says why."
  [[ $platform == linux ]] || where="${NIGHT_SHIFT_LOG:-The launchd log} says why."
  mkdir -p "$state_dir"
  if [[ ${SERVICE_RESULT-} == success ]]; then
    rm -f "$f" "$f.pushed"
    return 0
  fi
  [[ -r $f ]] && n=$(<"$f")
  [[ $n =~ ^[0-9]+$ ]] || n=0
  n=$((n + 1))
  echo "$n" >"$f"
  why="${SERVICE_RESULT:-unknown}${EXIT_STATUS:+ $EXIT_STATUS}"
  echo "night-shift: $n run(s) in a row failed, the last with $why" >&2
  if ((n >= failed_runs)) && [[ ! -e $f.pushed ]]; then
    if notify "Night shift is failing" \
      "The last $n runs failed, the last with $why, so nothing is taken from Linear or started. $where"; then
      touch "$f.pushed"
    fi
  fi
}

status() {
  local any="" report
  for f in "$state_dir"/*.json; do
    any=1
    jq -r '"\(.ident)  \(.phase)  since \(.started // .labelled)  \(.name // "")  \(.worktree // "")"' "$f"
    # Work mode's reports, which on forge are comments on the issue.
    report=$state_dir/$(jq -r .ident "$f").report.md
    [[ ! -f $report ]] || sed 's/^/    /' "$report"
  done
  # Work mode's settings for a session land_one kept, once the issue itself
  # is forgotten: delete one with `claude rm` of its session.
  for f in "$state_dir"/*.settings; do
    [[ -f ${f%.settings}.json ]] && continue
    any=1
    echo "$(basename "$f" .settings)  merged, but its worktree and session were kept; $f stays until you remove them"
  done
  [[ -n $any ]] || echo "nothing yet"
}

viewer=""
case ${1-} in
  run)
    mkdir -p "$state_dir"
    # One run at a time, whether the timer's or Nick's.
    exec 9>"$state_dir/lock"
    flock -n 9 || {
      echo "night-shift: a run is already going" >&2
      exit 0
    }
    # However the run ends. One that cannot reach Linear ends early, and
    # forge taken off AC and offline must still be let sleep.
    trap awake EXIT
    [[ $mode == forge ]] || load_config
    load_key
    viewer=$(gql 'query { viewer { id } }' | jq -r .viewer.id)
    run
    ;;
  # The per-issue halves of a run, each in its own process (child above).
  _finish | _start | _land)
    [[ $# -eq 3 ]] || usage
    [[ $mode == forge ]] || load_config
    load_key
    viewer=$2
    case $1 in
      _finish) finish_one "$3" ;;
      _start) if [[ $mode == work ]]; then work_start_one "$3"; else start_one "$3"; fi ;;
      _land) land_one "$3" ;;
    esac
    ;;
  # After every run of the unit, its ExecStopPost.
  _after) after_run ;;
  # launchd's entry on a Mac (home/night-shift.nix), for what systemd gives
  # forge's unit: an hour's deadline, as TimeoutStartSec, then after_run with
  # how the run ended, as ExecStopPost has it. At the deadline timeout ends
  # the run's whole process group, its children and their setup commands
  # with it, as stopping the unit ends its cgroup; claude's daemon, in a group
  # of its own (cl), stays. Not set up yet, with no config, it does nothing,
  # and that is no failure.
  _tick)
    if [[ -n ${NIGHT_SHIFT_LOG:-} && -f $NIGHT_SHIFT_LOG ]] && (($(stat -c %s "$NIGHT_SHIFT_LOG") > 5000000)); then
      mv "$NIGHT_SHIFT_LOG" "$NIGHT_SHIFT_LOG.old"
    fi
    [[ $mode == forge || -e ${NIGHT_SHIFT_CONFIG:-} ]] || exit 0
    echo "night-shift: run at $(now)"
    rc=0
    timeout --kill-after=60 3600 "$BASH" -euo pipefail "$0" run </dev/null || rc=$?
    case $rc in
      0) SERVICE_RESULT=success ;;
      124 | 137) SERVICE_RESULT=timeout ;;
      *) SERVICE_RESULT=exit-code ;;
    esac
    EXIT_STATUS=$rc after_run
    ;;
  file)
    [[ $mode == forge ]] || die "file is forge's: in work mode, issues are filed in Linear by hand"
    load_key
    file_drafts
    # So what was just filed is in the backlog without waiting for a run.
    backlog || echo "night-shift: backlog.md not written; the next run will" >&2
    ;;
  check)
    load_key
    if [[ $mode == work ]]; then
      load_config
      work_check
    else
      check
    fi
    ;;
  status) status ;;
  # An interactive session in the agents' sandbox, cld-safe's
  # (home/night-shift.nix).
  safe)
    [[ $mode == work ]] || die "safe is work mode's: on forge, every Claude session is sandboxed already"
    shift
    work_safe "$@"
    ;;
  # Work mode's answer to an agent that stopped: picked up by the next run,
  # which resumes the session with it (work_start_one).
  resume)
    [[ $# -eq 3 && -n $3 ]] || usage
    [[ $mode == work ]] || die "resume is work mode's; on forge, answer in Linear and move the issue back to $QUEUED"
    f=$state_dir/${2^^}.json
    [[ -f $f && $(jq -r .phase "$f") == waiting ]] || die "${2^^} has no agent waiting; night-shift status lists them"
    printf '%s\n' "$3" >"$state_dir/${2^^}.answer"
    # launchd's run now rather than at the next tick, when there is a job to
    # start (home/night-shift.nix). Without -k, a run already going is left
    # be, and the answer waits for whichever run next reaches the queue.
    if [[ -n ${NIGHT_SHIFT_LAUNCHD_LABEL:-} ]] &&
      launchctl kickstart "gui/$(id -u)/$NIGHT_SHIFT_LAUNCHD_LABEL" </dev/null >/dev/null 2>&1; then
      echo "night-shift: ${2^^} resumes in the run starting now, or the next if one is already going"
    else
      echo "night-shift: ${2^^} resumes on the next run; \`night-shift run\` starts one now"
    fi
    ;;
  *) usage ;;
esac
