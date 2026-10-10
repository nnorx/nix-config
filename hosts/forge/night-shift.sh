# The night shift: issues Nick queues in Linear, worked by background Claude
# Code agents on forge, each ending in a PR handoff for him to publish. See
# hosts/forge/night-shift.nix for how it runs and docs/night-shift.md for
# using it. Built with writeShellApplication, which adds the shebang, errexit,
# nounset and pipefail.
#
# An issue moves through the team's states:
#
#   Queued         Nick put it there. Taken when a slot is free, highest
#                  priority first, but only if Nick himself moved it there.
#   Running        An agent has it, in its own worktree and session.
#   Handoff ready  The agent committed and wrote a PR handoff. The comment
#                  says what changed, and for nix-config, preflight's verdict.
#   Needs you      The agent stopped with questions, or went quiet.
#
# Moving an issue back to Queued resumes its agent's session, in the same
# worktree, with Nick's comments since it stopped.
#
# Nothing here publishes, merges or deploys. Agents run in Claude Code's
# sandbox under Nick's settings; only this script, outside it, talks to Linear.

usage() {
  cat >&2 <<'EOF'
usage: night-shift run      take finished work back to Linear, then start queued work
       night-shift check    confirm the key, states, repo labels and tools
       night-shift status   what each issue's agent is doing
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

projects=${NIGHT_SHIFT_PROJECTS:-$HOME/projects}
max=${NIGHT_SHIFT_MAX:-2}
stall_hours=${NIGHT_SHIFT_STALL_HOURS:-4}
state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/night-shift
shopt -s nullglob

now() { date -u +%FT%TZ; }

# Read once and never exported, so the agents started below do not inherit
# it. It reaches curl through a file descriptor rather than the command line,
# which any of Nick's processes could read from /proc.
key=""
load_key() {
  [[ -r ${NIGHT_SHIFT_KEY_FILE:-} ]] || die "cannot read the Linear key at '${NIGHT_SHIFT_KEY_FILE:-}'"
  key=$(<"$NIGHT_SHIFT_KEY_FILE")
}

# gql <query> [variables json]: the response's data. Exits 1 when Linear
# cannot be reached and 2 when it answers with an error, such as an issue
# that no longer exists, so a caller can tell "gone" from "offline".
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
    exit 2
  fi
  jq -c '.data' <<<"$out"
}

# notify <title> <message> <url>. Best effort: a missed push leaves the issue
# itself correct. The topic is the only access control, so it goes through a
# descriptor too.
notify() {
  [[ -r ${NIGHT_SHIFT_NTFY_FILE:-} ]] || return 0
  curl -sS --max-time 15 -o /dev/null \
    -K <(printf 'url = %s\n' "$(<"$NIGHT_SHIFT_NTFY_FILE")") \
    -H "Title: $1" -H "Click: $3" -H "Tags: robot" --data-binary "$2" ||
    echo "night-shift: ntfy failed for: $1" >&2
}

# One issue in full. The whole history, in whatever order Linear returns it,
# so the check on who queued it does not depend on the order.
ISSUE_FIELDS='id identifier title description url
  state { name type }
  creator { id }
  team { states { nodes { id name } } }
  labels { nodes { name parent { name } } }
  comments(first: 100) { nodes { body createdAt user { id } } }
  history(first: 250) { pageInfo { hasNextPage } nodes { createdAt actorId toState { name } } }'

issue() {
  gql "query(\$id: String!) { issue(id: \$id) { $ISSUE_FIELDS } }" \
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

# stop_issue <issue json> <state> <markdown> <push title>
stop_issue() {
  comment "$1" "$3"
  move "$1" "$2"
  notify "$4" "$(jq -r .title <<<"$1")" "$(jq -r .url <<<"$1")"
  echo "night-shift: $4"
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

# update <state file> <jq filter> [jq args...]
update() {
  local f=$1 filter=$2
  shift 2
  jq "$@" "$filter" "$f" >"$f.tmp"
  mv "$f.tmp" "$f"
}

# claude without the run lock's descriptor. Any claude command can start the
# background daemon, which would hold the lock, and keep every later run out,
# for as long as it lives.
cl() {
  claude "$@" 9>&-
}

closed() {
  [[ $(jq -r .state.type <<<"$1") == completed || $(jq -r .state.type <<<"$1") == canceled ]]
}

# agent <field> <name> <worktree>: a field of the background agent with that
# name in that worktree, or nothing. `sessionId` is what --resume takes, `id`
# the short one `claude stop` takes. `claude --bg` picks them itself and
# ignores --session-id, so this asks its roster rather than choosing one.
agent() {
  cl agents --json --all </dev/null 2>/dev/null |
    jq -r --arg f "$1" --arg n "$2" --arg wt "$3" \
      'map(select(.name == $n and .cwd == $wt)) | last | .[$f] // empty' || true
}

prompt_new() {
  local issue=$1 repo=$2 wt=$3 branch=$4 base=$5 result=$6 comments
  comments=$(answers "$issue")
  cat <<EOP
You are the night shift: an unattended Claude Code session working on a task
Nick queued in Linear. Nobody is watching. He reads what you leave when he is
next at his desk, often the next morning.

# $(jq -r '"\(.identifier): \(.title)"' <<<"$issue")

$(jq -r '.description // "(no description)"' <<<"$issue")

## Nick's comments on the issue, oldest first

${comments:-(none)}

## How to work

- You are in a git worktree of $(basename "$repo") at $wt, on branch $branch,
  made from $base. Read the repository's CLAUDE.md first. Where it and this
  prompt disagree, CLAUDE.md wins, except that you never push, merge or deploy.
- Make the change the task asks for, as one pull request. If it has to grow
  beyond that, stop and ask.
- Run the checks the repository names. Commit on this branch without renaming
  it, then write the PR handoff with the core plugin's pr-handoff skill, so
  Nick can publish it with \`pr-handoff\` from this worktree. Touch no other
  worktree.
- Stop and ask rather than guess when a decision is Nick's, when the task is
  ambiguous, or when a check fails for a reason outside the task. A stopped
  task costs him one look; one that improvised costs a review of all of it.

## When you finish or stop

Write $result, then end your turn:

- The first line is exactly \`handoff\` or \`blocked\`.
- After a handoff: what changed and what you verified, in a few lines.
- When blocked: what you did so far, then numbered questions, each answerable
  in a sentence.

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

# Runs a command with what Claude Code's sandbox denies hidden: forge's sops
# secrets, the age key, the session bus and other sockets, the ssh agent, and
# gh's login. The brief evaluates the agent's branch, which is code the agent
# wrote, and evaluation can read files; without this it would read them as
# Nick, outside the sandbox the agent was held to.
confined() {
  local args=(--dev-bind / /) p
  for p in /run/secrets.d /run/user /tmp/.X11-unix "$HOME/.config/sops" "$HOME/.config/gh" \
    "$HOME/.ssh/agent" /tmp/org.chromium.Chromium.*; do
    if [[ -d $p ]]; then
      args+=(--tmpfs "$p")
    elif [[ -e $p ]]; then
      args+=(--ro-bind /dev/null "$p")
    fi
  done
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

# report: stop_issue for a result, except that an issue Nick has already
# moved back to Queued, while its agent worked, stays there. The same run then
# resumes it with his new comments, rather than leaving them unanswered.
report() {
  if [[ $(jq -r .state.name <<<"$1") == "$QUEUED" ]]; then
    comment "$1" "$3"
    echo "night-shift: $4, left in $QUEUED"
  else
    stop_issue "$@"
  fi
}

# One running issue: take its result back to Linear, or flag it as quiet.
finish_one() {
  local f=$1 id ident repo wt branch name started result kind body i rc=0 verdict level
  [[ $(jq -r .phase "$f") == running ]] || return 0
  id=$(jq -r .id "$f")
  ident=$(jq -r .ident "$f")
  repo=$(jq -r .repo "$f")
  wt=$(jq -r .worktree "$f")
  branch=$(jq -r .branch "$f")
  name=$(jq -r .name "$f")
  started=$(jq -r .started "$f")
  result=$(result_path "$repo" "$ident")

  if [[ ! -f $result ]] && (($(date +%s) - $(date -d "$started" +%s) <= stall_hours * 3600)); then
    return 0
  fi
  i=$(issue "$id") || rc=$?
  if ((rc == 2)) || { ((rc == 0)) && closed "$i"; }; then
    # Deleted, done or canceled while the agent worked: leave it closed.
    archive "$result"
    rm "$f"
    echo "night-shift: forgot $ident, closed while running"
    return 0
  fi
  ((rc == 0)) || return "$rc"

  if [[ ! -f $result ]]; then
    report "$i" "$NEEDS" "No result after $stall_hours hours. \`claude attach $name\` shows where it is; move this back to $QUEUED to nudge it." \
      "$ident went quiet"
  else
    kind=$(head -n 1 "$result" | tr -d '[:space:]')
    body=$(tail -n +2 "$result")
    if [[ $kind == handoff ]]; then
      verdict=$(brief "$repo" "$branch")
      # "be there" from "**Preflight: be there.** ...", for the push.
      level=$(sed -nE '1s/^\*\*Preflight: ([^.]*)\..*/ (\1)/p' <<<"$verdict")
      report "$i" "$READY" "Handoff ready on \`$branch\`.

$body
${verdict:+
$verdict
}
To publish: \`cd $wt && pr-handoff\`. To talk to the agent: \`claude attach $name\`." \
        "$ident handoff ready$level"
    else
      report "$i" "$NEEDS" "The agent stopped and needs you.

$body

Answer in a comment and move this back to $QUEUED to resume it, or \`claude attach $name\`." \
        "$ident needs you"
    fi
    archive "$result"
  fi
  update "$f" '.phase = "waiting"'
}

# One queued issue: start an agent on it, or resume the one it had.
start_one() {
  local id=$1 i ident queuer f label repo base name wt branch session job result
  i=$(issue "$id")
  [[ $(jq -r .state.name <<<"$i") == "$QUEUED" ]] || return 0
  ident=$(jq -r .identifier <<<"$i")
  f=$state_dir/$ident.json

  # Whoever last moved it into Queued, or created it there. Anything synced
  # in from elsewhere, a public repo's issues say, can reach the state; only
  # Nick's own hand starts an agent.
  if [[ $(jq -r .history.pageInfo.hasNextPage <<<"$i") == true ]]; then
    stop_issue "$i" "$NEEDS" "Not started: its history is too long to tell who queued it. Start it with \`claude\` instead." "$ident was not started"
    return 0
  fi
  queuer=$(jq -r --arg q "$QUEUED" \
    '([.history.nodes[] | select(.toState.name == $q)] | max_by(.createdAt) | .actorId) // .creator.id' <<<"$i")
  if [[ $queuer != "$viewer" ]]; then
    stop_issue "$i" "$NEEDS" "Not started: only issues you move to $QUEUED yourself are taken." "$ident was not queued by you"
    return 0
  fi

  if [[ -f $f && $(jq -r .phase "$f") == running ]]; then
    # Moved back by hand while its agent still works: it already has it.
    move "$i" "$RUNNING"
    return 0
  fi

  if [[ -f $f ]]; then
    repo=$(jq -r .repo "$f")
    wt=$(jq -r .worktree "$f")
    name=$(jq -r .name "$f")
    # The roster first; the id saved at start covers a roster that has
    # forgotten the session.
    session=$(agent sessionId "$name" "$wt")
    [[ -n $session ]] || session=$(jq -r '.session // empty' "$f")
    if [[ -z $session ]]; then
      stop_issue "$i" "$NEEDS" "Could not find the agent's session to resume in \`$wt\`." "$ident did not resume"
      return 0
    fi
    result=$(result_path "$repo" "$ident")
    # A result written after the agent was marked quiet is stale now.
    archive "$result"
    # --resume continues the session under the same id only if it is stopped
    # and given no flags; otherwise it starts a copy under a new id. A finished
    # session keeps its process, so stop it first. Its name and permission
    # mode are saved with it, and passing them again counts as new flags.
    job=$(agent id "$name" "$wt")
    [[ -z $job ]] || cl stop "$job" </dev/null >/dev/null 2>&1 || true
    if ! (cd "$wt" && cl --bg --resume "$session" </dev/null \
      "$(prompt_resume "$i" "$(jq -r .since "$f")" "$result")") >/dev/null; then
      stop_issue "$i" "$NEEDS" "Could not resume the session in \`$wt\`." "$ident did not resume"
      return 0
    fi
    session=$(agent sessionId "$name" "$wt")
    # shellcheck disable=SC2016 # jq's variables, not the shell's
    update "$f" '.phase = "running" | .started = $now | .since = $now
      | if $session != "" then .session = $session else . end' \
      --arg now "$(now)" --arg session "$session"
  else
    label=$(jq -r '[.labels.nodes[] | select(.parent.name == "repo") | .name] | first // ""' <<<"$i")
    repo=$projects/$label
    if [[ ! $label =~ ^[A-Za-z0-9._-]+$ ]] || ! git -C "$repo" remote get-url origin >/dev/null 2>&1; then
      stop_issue "$i" "$NEEDS" "Not started: give it a \`repo\` label naming a repository in $projects with an \`origin\`." "$ident has no repo"
      return 0
    fi
    # Offline, say: leave it queued for the next run.
    git -C "$repo" fetch --quiet origin || die "$ident: could not fetch $label; trying again next run"
    base=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD || echo origin/main)
    name="${ident,,}-$(jq -r .title <<<"$i" | slug)"
    wt=$repo/.claude/worktrees/$name
    branch=worktree-$name
    if ! git -C "$repo" worktree add --quiet -b "$branch" "$wt" "$base"; then
      stop_issue "$i" "$NEEDS" "Not started: could not make the worktree \`$wt\` on \`$branch\`. One may be left from an earlier run." "$ident has no worktree"
      return 0
    fi
    result=$(result_path "$repo" "$ident")
    mkdir -p "$(dirname "$result")"
    if ! (cd "$wt" && cl --bg -n "$name" --permission-mode auto </dev/null \
      "$(prompt_new "$i" "$repo" "$wt" "$branch" "$base" "$result")") >/dev/null; then
      stop_issue "$i" "$NEEDS" "Not started: \`claude --bg\` failed in \`$wt\`." "$ident did not start"
      return 0
    fi
    # May be empty if the roster lags; a resume asks again.
    session=$(agent sessionId "$name" "$wt")
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

# Forgets waiting issues Nick has closed. Their worktrees stay for `claude rm`
# or git's cleanup, since one may hold work not yet published. Only an answer
# from Linear counts: offline, nothing is forgotten.
tidy() {
  local f i rc
  for f in "$state_dir"/*.json; do
    [[ $(jq -r .phase "$f") == waiting ]] || continue
    rc=0
    i=$(issue "$(jq -r .id "$f")") || rc=$?
    if ((rc == 2)) || { ((rc == 0)) && closed "$i"; }; then
      rm "$f"
      echo "night-shift: forgot $(basename "$f" .json)"
    fi
  done
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
# whole run. The children hold the lock too: stopping the unit kills only the
# main process (KillMode), and a child left finishing an issue must keep the
# next run off it. Only `claude` goes without (see cl).
child() {
  "$BASH" -euo pipefail "$0" "$@" || echo "night-shift: $1 ${*: -1} failed; next run tries again" >&2
}

run() {
  local f queued id
  for f in "$state_dir"/*.json; do
    child _finish "$viewer" "$f"
  done
  tidy
  # shellcheck disable=SC2016 # GraphQL's variables, not the shell's
  queued=$(gql 'query($s: String!) { issues(first: 50, filter: {state: {name: {eq: $s}}}) { nodes { id priority createdAt } } }' \
    "$(jq -nc --arg s "$QUEUED" '{s: $s}')" |
    jq -r '.issues.nodes | sort_by((if .priority == 0 then 5 else .priority end), .createdAt) | .[].id')
  for id in $queued; do
    (($(running) < max)) || break
    child _start "$viewer" "$id"
  done
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
status() {
  local any=""
  for f in "$state_dir"/*.json; do
    any=1
    jq -r '"\(.ident)  \(.phase)  since \(.started)  \(.name)  \(.worktree)"' "$f"
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
    load_key
    viewer=$(gql 'query { viewer { id } }' | jq -r .viewer.id)
    run
    ;;
  # The per-issue halves of a run, each in its own process (child above).
  _finish | _start)
    [[ $# -eq 3 ]] || usage
    load_key
    viewer=$2
    if [[ $1 == _finish ]]; then finish_one "$3"; else start_one "$3"; fi
    ;;
  check)
    load_key
    check
    ;;
  status) status ;;
  *) usage ;;
esac
