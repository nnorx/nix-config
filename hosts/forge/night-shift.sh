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

# Read once and never exported, so the agents started below do not inherit
# it. It reaches curl through a file descriptor rather than the command line,
# which any of Nick's processes could read from /proc.
key=""
load_key() {
  [[ -r ${NIGHT_SHIFT_KEY_FILE:-} ]] || die "cannot read the Linear key at '${NIGHT_SHIFT_KEY_FILE:-}'"
  key=$(<"$NIGHT_SHIFT_KEY_FILE")
}

# gql <query> [variables json]: the response's data, or die with its error.
gql() {
  local body out
  body=$(jq -nc --arg q "$1" --argjson v "${2:-"{}"}" '{query: $q, variables: $v}')
  out=$(curl -sS --max-time 30 -K <(printf 'header = "Authorization: %s"\n' "$key") \
    -H 'Content-Type: application/json' --data-binary "$body" \
    https://api.linear.app/graphql) || die "Linear did not answer"
  if jq -e '.errors' <<<"$out" >/dev/null; then
    die "Linear: $(jq -r '.errors | map(.message) | join("; ")' <<<"$out")"
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

ISSUE_FIELDS='id identifier title description url priority createdAt
  state { type }
  creator { id }
  team { states { nodes { id name } } }
  labels { nodes { name parent { name } } }
  comments(first: 100) { nodes { body createdAt user { id } } }
  history(first: 50) { nodes { createdAt actorId toState { name } } }'

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
}

# Nick's comments, oldest first, after <since> when given, without this
# script's own.
answers() {
  jq -r --arg since "${2:-}" --arg me "$viewer" '
    [.comments.nodes[]
     | select(.user.id == $me and (.body | startswith("**Night shift**") | not))
     | select($since == "" or .createdAt > $since)]
    | sort_by(.createdAt)
    | map("[\(.createdAt[:16] | sub("T"; " "))] \(.body)") | join("\n\n")' <<<"$1"
}

common_dir() {
  git -C "$1" rev-parse --path-format=absolute --git-common-dir
}

save() {
  jq -n "$@" >"$state_dir/$ident.json.tmp"
  mv "$state_dir/$ident.json.tmp" "$state_dir/$ident.json"
}

result_path() {
  echo "$(common_dir "$1")/night-shift/$2.md"
}

prompt_new() {
  local issue=$1 repo=$2 wt=$3 branch=$4 base=$5 result=$6 comments
  comments=$(answers "$issue")
  cat <<EOF
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
EOF
}

prompt_resume() {
  local issue=$1 since=$2 result=$3 new lead=" without a new comment."
  new=$(answers "$issue" "$since")
  [[ -z $new ]] || lead=", with these comments since you stopped:"
  cat <<EOF
Nick re-queued $(jq -r .identifier <<<"$issue") in Linear$lead

${new}

Carry on under the same rules. When you finish or stop again, write $result
the same way, and end your turn.
EOF
}

slug() {
  tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//' | cut -c1-32 | sed 's/-$//'
}

# The verdict and its findings from preflight's brief, for repos that have it.
brief() {
  local repo=$1 branch=$2 out
  [[ -f $repo/scripts/preflight-brief.jq ]] || return 0
  out=$(mktemp)
  if (cd "$repo" && nix run .#preflight -- --head "$branch" --json "$out" </dev/null >/dev/null 2>&1); then
    jq -r '"**Preflight: \(.verdict.level).** \(.verdict.text)",
      (.hosts | to_entries[] | .key as $h | .value.findings[]
        | select(.level != "note") | "- \($h), \(.level): \(.text)"),
      (.plan[] | select(.level != "note") | "- \(.level): \(.text)")' "$out"
  else
    echo "**Preflight failed** on this branch. Run \`nix run .#preflight -- --head $branch\` to see why."
  fi
  rm -f "$out"
}

# Takes back every issue whose agent wrote its result, or went quiet.
finish() {
  local f ident repo wt branch name started result kind body i verdict level
  for f in "$state_dir"/*.json; do
    [[ $(jq -r .phase "$f") == running ]] || continue
    ident=$(jq -r .ident "$f")
    repo=$(jq -r .repo "$f")
    wt=$(jq -r .worktree "$f")
    branch=$(jq -r .branch "$f")
    name=$(jq -r .name "$f")
    started=$(jq -r .started "$f")
    result=$(result_path "$repo" "$ident")

    if [[ -f $result ]]; then
      i=$(issue "$(jq -r .id "$f")")
      kind=$(head -n 1 "$result" | tr -d '[:space:]')
      body=$(tail -n +2 "$result")
      if [[ $kind == handoff ]]; then
        verdict=$(brief "$repo" "$branch")
        # "be there" from "**Preflight: be there.** ...", for the push.
        level=$(sed -nE '1s/^\*\*Preflight: ([^.]*)\..*/ (\1)/p' <<<"$verdict")
        stop_issue "$i" "$READY" "Handoff ready on \`$branch\`.

$body
${verdict:+
$verdict
}
To publish: \`cd $wt && pr-handoff\`. To talk to the agent: \`claude attach $name\`." \
          "$ident handoff ready$level"
      else
        stop_issue "$i" "$NEEDS" "The agent stopped and needs you.

$body

Answer in a comment and move this back to $QUEUED to resume it, or \`claude attach $name\`." \
          "$ident needs you"
      fi
      mv "$result" "$result.$(date +%s)"
      jq --arg now "$(date -u +%FT%TZ)" '.phase = "waiting" | .since = $now' "$f" >"$f.tmp" && mv "$f.tmp" "$f"

    elif (($(date +%s) - $(date -d "$started" +%s) > stall_hours * 3600)); then
      i=$(issue "$(jq -r .id "$f")")
      stop_issue "$i" "$NEEDS" "No result after $stall_hours hours. \`claude attach $name\` shows where it is; move this back to $QUEUED to nudge it." \
        "$ident went quiet"
      jq --arg now "$(date -u +%FT%TZ)" '.phase = "waiting" | .since = $now' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
    fi
  done
}

# Forgets issues Nick has closed, done or canceled. Their worktrees stay for
# `claude rm` or git's cleanup, since one may hold work not yet published.
tidy() {
  local f type
  for f in "$state_dir"/*.json; do
    [[ $(jq -r .phase "$f") == waiting ]] || continue
    # Linear answers a deleted issue with an error, which is the same as gone.
    type=$(issue "$(jq -r .id "$f")" | jq -r '.state.type // "gone"') || type=gone
    if [[ $type == completed || $type == canceled || $type == gone ]]; then
      rm "$f"
      echo "night-shift: forgot $(basename "$f" .json), $type"
    fi
  done
}

# Starts or resumes queued issues while slots are free.
start() {
  local running=0 queued i ident queuer label repo base name wt branch session result since
  local states=("$state_dir"/*.json)
  if ((${#states[@]})); then
    running=$(jq -s '[.[] | select(.phase == "running")] | length' "${states[@]}")
  fi
  queued=$(gql "query(\$s: String!) { issues(first: 50, filter: {state: {name: {eq: \$s}}}) { nodes { $ISSUE_FIELDS } } }" \
    "$(jq -nc --arg s "$QUEUED" '{s: $s}')" |
    jq -c '.issues.nodes | sort_by((if .priority == 0 then 5 else .priority end), .createdAt) | .[]')

  while IFS= read -r i; do
    [[ -n $i ]] || continue
    ((running < max)) || break
    ident=$(jq -r .identifier <<<"$i")

    # Whoever last moved it into Queued, or created it there. Anything synced
    # in from elsewhere, a public repo's issues say, can reach the state; only
    # Nick's own hand starts an agent.
    queuer=$(jq -r --arg q "$QUEUED" \
      '([.history.nodes[] | select(.toState.name == $q)] | max_by(.createdAt) | .actorId) // .creator.id' <<<"$i")
    if [[ $queuer != "$viewer" ]]; then
      stop_issue "$i" "$NEEDS" "Not started: only issues you move to $QUEUED yourself are taken." "$ident was not queued by you"
      continue
    fi

    if [[ -f $state_dir/$ident.json ]]; then
      repo=$(jq -r .repo "$state_dir/$ident.json")
      wt=$(jq -r .worktree "$state_dir/$ident.json")
      session=$(jq -r .session "$state_dir/$ident.json")
      since=$(jq -r .since "$state_dir/$ident.json")
      result=$(result_path "$repo" "$ident")
      (cd "$wt" && claude --bg --resume "$session" --permission-mode auto </dev/null \
        "$(prompt_resume "$i" "$since" "$result")") >/dev/null ||
        {
          stop_issue "$i" "$NEEDS" "Could not resume the session in \`$wt\`." "$ident did not resume"
          continue
        }
      jq --arg now "$(date -u +%FT%TZ)" '.phase = "running" | .started = $now' \
        "$state_dir/$ident.json" >"$state_dir/$ident.json.tmp" && mv "$state_dir/$ident.json.tmp" "$state_dir/$ident.json"
    else
      label=$(jq -r '[.labels.nodes[] | select(.parent.name == "repo") | .name] | first // ""' <<<"$i")
      repo=$projects/$label
      if [[ ! $label =~ ^[A-Za-z0-9._-]+$ ]] || ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
        stop_issue "$i" "$NEEDS" "Not started: give it a \`repo\` label naming a repository in $projects." "$ident has no repo"
        continue
      fi
      git -C "$repo" fetch --quiet origin
      base=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD || echo origin/main)
      name="${ident,,}-$(jq -r .title <<<"$i" | slug)"
      wt=$repo/.claude/worktrees/$name
      branch=worktree-$name
      if ! git -C "$repo" worktree add --quiet -b "$branch" "$wt" "$base"; then
        stop_issue "$i" "$NEEDS" "Not started: could not make the worktree \`$wt\` on \`$branch\`. One may be left from an earlier run." "$ident has no worktree"
        continue
      fi
      result=$(result_path "$repo" "$ident")
      mkdir -p "$(dirname "$result")"
      session=$(cat /proc/sys/kernel/random/uuid)
      if ! (cd "$wt" && claude --bg -n "$name" --session-id "$session" --permission-mode auto </dev/null \
        "$(prompt_new "$i" "$repo" "$wt" "$branch" "$base" "$result")") >/dev/null; then
        stop_issue "$i" "$NEEDS" "Not started: \`claude --bg\` failed in \`$wt\`." "$ident did not start"
        continue
      fi
      # shellcheck disable=SC2016 # jq's variables, not the shell's
      save --arg id "$(jq -r .id <<<"$i")" --arg ident "$ident" --arg repo "$repo" \
        --arg worktree "$wt" --arg branch "$branch" --arg name "$name" --arg session "$session" \
        --arg now "$(date -u +%FT%TZ)" \
        '{id: $id, ident: $ident, repo: $repo, worktree: $worktree, branch: $branch,
          name: $name, session: $session, phase: "running", started: $now, since: $now}'
    fi
    move "$i" "$RUNNING"
    running=$((running + 1))
    echo "night-shift: started $ident"
  done <<<"$queued"
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
    finish
    tidy
    start
    ;;
  check)
    load_key
    check
    ;;
  status) status ;;
  *) usage ;;
esac
