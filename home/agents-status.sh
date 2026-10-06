# Where each branch of a batch of parallel agents stands, and what to merge
# next. See home/agents-status.nix. Built with writeShellApplication, which
# adds the shebang, errexit, nounset and pipefail.
#
# Reads git, never changes it. The live state of the agents themselves is
# `claude agents`; this answers the questions that come after: which branches
# have a handoff or a PR, whether CI passed, and which would conflict with
# main or with each other once one of them merges.

usage() {
  cat >&2 <<'EOF'
usage: agents-status [--offline]
       every local branch ahead of the default branch: handoff, PR, checks,
       and conflicts with the default branch and with each other
  --offline   skip GitHub; show only what git knows
EOF
  exit 64
}

offline=""
case ${1-} in
  "") ;;
  --offline) offline=1 ;;
  *) usage ;;
esac

git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "agents-status: not in a git repository" >&2
  exit 1
}
common=$(git rev-parse --path-format=absolute --git-common-dir)

if ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD); then
  default=${ref#origin/}
else
  default=main
fi
git fetch --quiet origin 2>/dev/null || echo "!! fetch failed; origin/$default may be stale"
base="origin/$default"

# owner/repo, for GitHub only. Empty for anything else, which skips the PR
# columns rather than failing.
slug=$(git remote get-url origin 2>/dev/null |
  sed -nE 's#^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+/[^/]+)$#\2#p')
slug=${slug%.git}
[[ -n $slug ]] || offline=1

# gh where it is logged in, which also covers private repos. The public API
# otherwise, unauthenticated and limited to 60 requests an hour, two per
# branch here: enough for a batch.
use_gh=""
if [[ -z $offline ]] && gh auth status >/dev/null 2>&1; then
  use_gh=1
fi

# Prints "<number> <state> <head sha> <checks>" for the newest PR from a
# branch, or "- none - -". checks is passed, failed, running or none.
pr_info() {
  local branch=$1 json
  if [[ -n $use_gh ]]; then
    json=$(gh pr list --repo "$slug" --head "$branch" --state all --limit 1 \
      --json number,state,headRefOid,statusCheckRollup 2>/dev/null) || json='[]'
    jq -r '
      if length == 0 then "- none - -" else .[0] |
        [(.statusCheckRollup // [])[] | (.conclusion // .state // "") | ascii_upcase] as $c |
        [(.statusCheckRollup // [])[] | select((.status // "COMPLETED") != "COMPLETED" or .state == "PENDING")] as $run |
        "\(.number) \(.state | ascii_downcase) \(.headRefOid) " +
        (if ($c | any(. == "FAILURE" or . == "ERROR" or . == "CANCELLED" or . == "TIMED_OUT")) then "failed"
         elif ($run | length) > 0 then "running"
         elif ($c | length) == 0 then "none"
         else "passed" end)
      end' <<<"$json"
    return
  fi
  local api="https://api.github.com/repos/$slug" pr number state sha
  pr=$(curl -fsS "$api/pulls?head=${slug%%/*}:$branch&state=all&per_page=1" 2>/dev/null) || {
    echo "- unknown - -"
    return
  }
  read -r number state sha < <(jq -r '
    if length == 0 then "- none -" else .[0] |
      "\(.number) \(if .merged_at then "merged" else .state end) \(.head.sha)"
    end' <<<"$pr")
  if [[ $number == - ]]; then
    echo "- none - -"
    return
  fi
  checks=$(curl -fsS "$api/commits/$sha/check-runs" 2>/dev/null | jq -r '
    [.check_runs[]] as $r |
    if ($r | any(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out")) then "failed"
    elif ($r | any(.status != "completed")) then "running"
    elif ($r | length) == 0 then "none"
    else "passed" end') || checks=unknown
  echo "$number $state $sha $checks"
}

# Worktree path per branch, from the porcelain listing.
declare -A wt_of=()
while read -r key value; do
  case $key in
    worktree) path=$value ;;
    branch) wt_of[${value#refs/heads/}]=$path ;;
  esac
done < <(git worktree list --porcelain)

# The branches in play: ahead of the default branch, and not already merged
# with their remote branch deleted (`git cleanup` removes those).
branches=()
while read -r branch track; do
  [[ $branch != "$default" ]] || continue
  [[ $track != "[gone]" ]] || continue
  [[ $(git rev-list --count "$base..$branch") -gt 0 ]] || continue
  branches+=("$branch")
done < <(git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads)

if [[ ${#branches[@]} -eq 0 ]]; then
  echo "No branches ahead of $base."
  exit 0
fi

# A worktree under .claude/worktrees/ is named for its task, which is what a
# dispatch plan's merge order lists; the branch may have been renamed since.
task_of() {
  local path=${wt_of[$1]-}
  if [[ $path == */.claude/worktrees/* ]]; then
    basename "$path"
  else
    echo "$1"
  fi
}

declare -A files_of=() ready=() state_of=()
for b in "${branches[@]}"; do
  files_of[$b]=$(git diff --name-only "$base...$b")
done

for b in "${branches[@]}"; do
  task=$(task_of "$b")
  path=${wt_of[$b]-}
  ahead=$(git rev-list --count "$base..$b")
  behind=$(git rev-list --count "$b..$base")

  if [[ $task != "$b" ]]; then
    echo "$b  (task $task)"
  else
    echo "$b"
  fi

  line="  $ahead ahead, $behind behind $default"
  if [[ -n $path && -n $(git -C "$path" status --porcelain --untracked-files=no) ]]; then
    line+=", uncommitted changes (still working?)"
  fi
  echo "$line"

  if [[ -s $common/pr-handoff/$b.squash.md ]]; then
    handoff="handoff and squash message written"
  elif [[ -s $common/pr-handoff/$b.md ]]; then
    handoff="handoff written"
  else
    handoff="no handoff"
  fi

  state=none
  if [[ -n $offline ]]; then
    echo "  $handoff"
  else
    read -r number state sha checks < <(pr_info "$b")
    case $state in
      none) echo "  $handoff, no PR" ;;
      unknown) echo "  $handoff, PR unknown (GitHub did not answer)" ;;
      *)
        line="  $handoff, PR #$number $state, checks $checks"
        if [[ $state == open && $sha != "$(git rev-parse "$b")" ]]; then
          line+=", local commits not published"
        fi
        echo "$line"
        ;;
    esac
  fi
  state_of[$b]=$state

  if git merge-tree --write-tree --quiet "$base" "$b" >/dev/null 2>&1; then
    main_ok=1
    conflicts="merges cleanly into $default"
  else
    main_ok=""
    conflicts="CONFLICTS with $default, rebase first"
  fi
  echo "  $conflicts"

  # Against each other branch: a real conflict once both merge, or just the
  # same file touched, which merges but deserves a look at review.
  for o in "${branches[@]}"; do
    [[ $o != "$b" ]] || continue
    shared=$(comm -12 <(sort <<<"${files_of[$b]}") <(sort <<<"${files_of[$o]}") | paste -sd ' ')
    [[ -n $shared ]] || continue
    if git merge-tree --write-tree --quiet "$o" "$b" >/dev/null 2>&1; then
      echo "  shares $shared with $o"
    else
      echo "  CONFLICTS with $o in $shared"
    fi
  done

  # "none" too: a repo without CI has nothing to wait for.
  if [[ -n $main_ok && $state == open && ${checks-} == @(passed|none) ]]; then
    ready[$b]=1
  fi
  echo
done

# The plan's merge order when a dispatch plan lists these tasks, so the
# suggestion follows what was decided rather than a guess. The newest plan
# wins; its "## Merge order" is a numbered list of task names, which may be
# in backticks (\140).
plan=""
if [[ -d $common/agent-plans ]]; then
  plan=$(find "$common/agent-plans" -maxdepth 1 -name '*.md' -printf '%T@ %p\n' 2>/dev/null |
    sort -rn | head -n 1 | cut -d' ' -f2-)
fi

order=()
if [[ -n $plan ]]; then
  while read -r task; do
    for b in "${branches[@]}"; do
      if [[ $(task_of "$b") == "$task" ]]; then
        order+=("$b")
      fi
    done
  done < <(sed -n '/^## Merge order/,/^## /p' "$plan" | tr -d '\140' |
    sed -nE 's/^[0-9]+\. +([A-Za-z0-9._/-]+).*/\1/p')
fi

if [[ ${#order[@]} -gt 0 ]]; then
  echo "Merge order, from $(basename "$plan"):"
  i=1
  for b in "${order[@]}"; do
    note=""
    if [[ ${state_of[$b]} == merged ]]; then
      note="  (merged)"
    elif [[ -n ${ready[$b]-} ]]; then
      note="  <- ready"
    fi
    echo "  $i. $b$note"
    i=$((i + 1))
  done
  for b in "${order[@]}"; do
    [[ ${state_of[$b]} != merged ]] || continue
    if [[ -n $offline ]]; then
      echo "Next in order is $b. Offline, so whether it is ready is unknown."
    elif [[ -n ${ready[$b]-} ]]; then
      echo "Next: merge $b."
    else
      echo "Next in order is $b, which is not ready yet."
    fi
    break
  done
elif [[ -z $offline ]]; then
  # No plan: open PRs with passing checks that merge cleanly. Merging one of
  # them changes nothing for the others unless they share a file, so those
  # come first.
  n=0
  for b in "${branches[@]}"; do
    [[ -n ${ready[$b]-} ]] || continue
    n=$((n + 1))
  done
  if [[ $n -eq 0 ]]; then
    echo "Nothing is ready to merge: no open PR with passing checks that merges cleanly."
  else
    echo "Ready to merge (no dispatch plan, so in no particular order):"
    for b in "${branches[@]}"; do
      if [[ -n ${ready[$b]-} ]]; then
        echo "  $b"
      fi
    done
    echo "After each merge, run this again: conflicts can change."
  fi
fi
