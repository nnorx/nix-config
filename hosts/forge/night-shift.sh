# The night shift: issues Nick queues in Linear, worked by background Claude
# Code agents on forge, each ending in a PR handoff for him to publish. See
# hosts/forge/night-shift.nix for how it runs and docs/night-shift.md for
# using it. Built with writeShellApplication, which adds the shebang, errexit,
# nounset and pipefail.
#
# An issue moves through the team's states:
#
#   Queued         Nick put it there. Taken when a slot is free, highest
#                  priority first, but only if Nick himself created it and
#                  moved it there.
#   Running        An agent has it, in its own worktree and session.
#   Handoff ready  The agent committed and wrote a PR handoff. The comment
#                  says what changed, and for nix-config, preflight's verdict.
#   Needs you      The agent stopped with questions, or went quiet.
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

# claude in a scope of its own, outside the unit, and without the run lock's
# descriptor. Any claude command can start the background daemon, which hosts
# every agent: in the unit's cgroup, stopping or finishing a run would kill
# them, and holding the lock it would keep every later run out.
cl() {
  systemd-run --user --scope --collect --quiet -- claude "$@" 9>&-
}

closed() {
  [[ $(jq -r .state.type <<<"$1") == completed || $(jq -r .state.type <<<"$1") == canceled ]]
}

# agent <name> <worktree>: "<id> <sessionId>" of the background agent with
# that name in that worktree, or nothing. The session id is what --resume
# takes, the short id what `claude stop` takes. `claude --bg` picks both itself
# and ignores --session-id, so this asks its roster rather than choosing one.
agent() {
  cl agents --json --all </dev/null 2>/dev/null |
    jq -r --arg n "$1" --arg wt "$2" \
      'map(select(.name == $n and .cwd == $wt)) | last | select(.) | "\(.id) \(.sessionId)"' || true
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
  if [[ $(jq -r .state.name <<<"$1") == "$QUEUED" ]]; then
    comment "$1" "$3"
    echo "night-shift: $4, left in $QUEUED"
  else
    stop_issue "$@"
  fi
}

# One running issue: take its result back to Linear, or flag it as quiet.
finish_one() {
  local f=$1 id ident repo wt branch name started result kind body i rc=0 verdict="" level session=""
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
  if [[ -f $result ]]; then
    kind=$(head -n 1 "$result" | tr -d '[:space:]')
    body=$(tail -n +2 "$result")
    # Preflight first: it takes minutes, and the issue's state is read after
    # it, so a re-queue made meanwhile counts.
    [[ $kind != handoff ]] || verdict=$(brief "$repo" "$branch")
    # The agent has just reported, so the roster surely lists it: keep its id
    # for a resume after the roster forgets.
    read -r _ session <<<"$(agent "$name" "$wt")" || true
    # shellcheck disable=SC2016 # jq's variables, not the shell's
    [[ -z ${session:-} ]] || update "$f" '.session = $s' --arg s "$session"
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
    if [[ $kind == handoff ]]; then
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
  local id=$1 i ident queuer f label repo base name wt branch session="" job="" result out copy
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
  # The title and description become the agent's task, given as Nick's, so
  # they must be his too. Synced and teammates' issues are not taken.
  if [[ $(jq -r '.creator.id // ""' <<<"$i") != "$viewer" ]]; then
    stop_issue "$i" "$NEEDS" "Not started: only issues you created are taken, since the agent is given the description as your task." "$ident is not yours"
    return 0
  fi

  if [[ -f $f && $(jq -r .phase "$f") == running ]]; then
    # Re-queued while its agent works: left in Queued, and resumed with the
    # new comments once its result is in (report).
    return 0
  fi

  if [[ -f $f ]]; then
    repo=$(jq -r .repo "$f")
    wt=$(jq -r .worktree "$f")
    name=$(jq -r .name "$f")
    # The roster first; the id saved earlier covers a roster that has
    # forgotten the session.
    read -r job session <<<"$(agent "$name" "$wt")" || true
    [[ -n ${session:-} ]] || session=$(jq -r '.session // empty' "$f")
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
    [[ -z ${job:-} ]] || cl stop "$job" </dev/null >/dev/null 2>&1 || true
    if ! out=$(cd "$wt" && cl --bg --resume "$session" </dev/null \
      "$(prompt_resume "$i" "$(jq -r .since "$f")" "$result")" 2>&1 >/dev/null); then
      stop_issue "$i" "$NEEDS" "Could not resume the session in \`$wt\`." "$ident did not resume"
      return 0
    fi
    echo "$out" >&2
    # claude says so when it started a copy instead, which would put two
    # agents in one worktree: stop it and let Nick decide.
    copy=$(sed -nE 's/.*started a copy as ([0-9a-f]+).*/\1/p' <<<"$out" | head -n 1)
    if [[ -n $copy ]]; then
      cl stop "$copy" </dev/null >/dev/null 2>&1 || true
      stop_issue "$i" "$NEEDS" "Not resumed: claude started a copy ($copy) instead of continuing the session, and the copy was stopped. \`claude attach ${job:-$session}\` opens the original." "$ident did not resume"
      return 0
    fi
    # shellcheck disable=SC2016 # jq's variables, not the shell's
    update "$f" '.phase = "running" | .started = $now | .since = $now | .session = $s' \
      --arg now "$(now)" --arg s "$session"
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
    # May be empty if the roster lags; finish_one and a resume ask again.
    read -r _ session <<<"$(agent "$name" "$wt")" || true
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
  # shellcheck disable=SC2016 # GraphQL's variables, not the shell's
  queued=$(gql 'query($s: String!) { issues(first: 50, filter: {state: {name: {eq: $s}}}) { nodes { id priority createdAt } } }' \
    "$(jq -nc --arg s "$QUEUED" '{s: $s}')" |
    jq -r '.issues.nodes | sort_by((if .priority == 0 then 5 else .priority end), .createdAt) | .[].id')
  for id in $queued; do
    (($(running) < max)) || break
    child _start "$viewer" "$id"
  done
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
  file)
    load_key
    file_drafts
    ;;
  check)
    load_key
    check
    ;;
  status) status ;;
  *) usage ;;
esac
