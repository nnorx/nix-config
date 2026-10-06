# Where each branch of a batch of parallel agents stands, and what to merge
# next. See home/agents-status.nix. Built with writeShellApplication, which
# adds the shebang, errexit, nounset and pipefail.
#
# Changes no branch and no working tree; the fetch only updates what origin's
# refs say. The live state of the agents themselves is `claude agents`; this
# answers the questions that come after: which branches have a handoff or a
# PR, whether CI passed, and which would conflict with main or with each other
# once one of them merges.

usage() {
  cat >&2 <<'EOF'
usage: agents-status [--offline]
       every local branch ahead of the default branch: handoff, PR, checks,
       and conflicts with the default branch and with each other
  --offline   no fetch and no GitHub; show only what git already knows
EOF
  exit 64
}

die() {
  echo "agents-status: $*" >&2
  exit 1
}

offline=""
case ${1-} in
  "") ;;
  --offline) offline=1 ;;
  *) usage ;;
esac

git rev-parse --git-dir >/dev/null 2>&1 || die "not in a git repository"
common=$(git rev-parse --path-format=absolute --git-common-dir)

# owner/repo, for GitHub only. Empty for any other remote, or none, which
# skips the PR lines rather than failing.
slug=$(git remote get-url origin 2>/dev/null |
  sed -nE 's#^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+/[^/]+)$#\2#p' || true)
slug=${slug%.git}

has_origin=""
if git remote get-url origin >/dev/null 2>&1; then
  has_origin=1
fi
if [[ -n $has_origin && -z $offline ]]; then
  git fetch --quiet origin 2>/dev/null || echo "!! fetch failed; comparing with what origin last sent"
fi

# gh where it is logged in, which also covers private repos. The public API
# otherwise, unauthenticated and limited to 60 requests an hour.
github=""
use_gh=""
if [[ -n $slug && -z $offline ]]; then
  github=1
  if gh auth status >/dev/null 2>&1; then
    use_gh=1
  fi
fi

# The default branch as pr-handoff finds it, then whichever of main and master
# exists. origin/HEAD is only set by a clone, not by `git remote add`.
default=""
if ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD); then
  default=${ref#origin/}
elif [[ -n $use_gh ]]; then
  default=$(gh repo view "$slug" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)
fi
if [[ -z $default ]]; then
  for d in main master; do
    if git rev-parse --verify --quiet "refs/remotes/origin/$d" >/dev/null ||
      git rev-parse --verify --quiet "refs/heads/$d" >/dev/null; then
      default=$d
      break
    fi
  done
fi
[[ -n $default ]] || die "cannot tell the default branch; try git remote set-head origin --auto"
if git rev-parse --verify --quiet "refs/remotes/origin/$default" >/dev/null; then
  base="origin/$default"
elif git rev-parse --verify --quiet "refs/heads/$default" >/dev/null; then
  base=$default
else
  die "neither origin/$default nor $default exists"
fi

# Worktree path per branch, from the porcelain listing.
declare -A wt_of=()
while read -r key value; do
  case $key in
    worktree) path=$value ;;
    branch) wt_of[${value#refs/heads/}]=$path ;;
  esac
done < <(git worktree list --porcelain)

# The branches in play: ahead of the default branch, and not already merged
# with their remote branch deleted (`git cleanup` removes those). A branch
# pushed under another name is looked up on GitHub by that name.
branches=()
declare -A ahead_of=() behind_of=() remote_name=()
while IFS=$'\t' read -r branch upstream track; do
  [[ $branch != "$default" ]] || continue
  [[ $track != "[gone]" ]] || continue
  read -r behind ahead < <(git rev-list --left-right --count "$base...$branch")
  [[ $ahead -gt 0 ]] || continue
  branches+=("$branch")
  ahead_of[$branch]=$ahead
  behind_of[$branch]=$behind
  if [[ $upstream == refs/remotes/origin/* ]]; then
    remote_name[$branch]=${upstream#refs/remotes/origin/}
  else
    remote_name[$branch]=$branch
  fi
done < <(git for-each-ref --format='%(refname:short)%09%(upstream)%09%(upstream:track)' refs/heads)

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

# --- GitHub: PRs, then checks for the open ones -----------------------------

# Check runs and commit statuses, as gh's statusCheckRollup gives them, to one
# word. Passed only when every one succeeded or was neutral or skipped, so
# action_required, startup_failure, stale and anything new count as failed.
verdict='
  map(if .__typename == "CheckRun" then
        (if (.status // "") != "COMPLETED" then "pending"
         elif ((.conclusion // "") | IN("SUCCESS", "NEUTRAL", "SKIPPED")) then "ok"
         else "fail" end)
      else
        (if .state == "SUCCESS" then "ok"
         elif ((.state // "") | IN("PENDING", "EXPECTED")) then "pending"
         else "fail" end)
      end) |
  if any(. == "fail") then "failed"
  elif any(. == "pending") then "running"
  elif length == 0 then "none"
  else "passed" end'

# One listing for every branch rather than a request each, newest PR first.
# PRs from forks are left out: their branch names can match ours.
declare -A pr_num=() pr_state=() pr_sha=()
prs_ok=""
if [[ -n $github ]]; then
  if [[ -n $use_gh ]]; then
    listing=$(gh pr list --repo "$slug" --state all --limit 200 \
      --json number,state,headRefName,headRefOid,isCrossRepository \
      -q '.[] | select(.isCrossRepository | not) |
        [.headRefName, .number, (.state | ascii_downcase), .headRefOid] | @tsv' 2>/dev/null) &&
      prs_ok=1
  else
    listing=$(curl -fsS "https://api.github.com/repos/$slug/pulls?state=all&per_page=100&sort=created&direction=desc" 2>/dev/null |
      jq -r --arg slug "$slug" '.[] | select(.head.repo.full_name? == $slug) |
        [.head.ref, .number, (if .merged_at then "merged" else .state end), .head.sha] | @tsv') &&
      prs_ok=1
  fi
  if [[ -n $prs_ok ]]; then
    while IFS=$'\t' read -r head number state sha; do
      [[ -n $head && -z ${pr_num[$head]-} ]] || continue
      pr_num[$head]=$number
      pr_state[$head]=$state
      pr_sha[$head]=$sha
    done <<<"$listing"
  fi
fi

declare -A state_of=()
for b in "${branches[@]}"; do
  if [[ -z $github ]]; then
    state_of[$b]=none
  elif [[ -z $prs_ok ]]; then
    state_of[$b]=unknown
  else
    state_of[$b]=${pr_state[${remote_name[$b]}]-none}
  fi
done

checks_of() {
  local number=$1 sha=$2 runs statuses
  if [[ -n $use_gh ]]; then
    gh pr view "$number" --repo "$slug" --json statusCheckRollup \
      -q ".statusCheckRollup // [] | $verdict" 2>/dev/null || echo unknown
    return
  fi
  local api="https://api.github.com/repos/$slug/commits/$sha"
  if runs=$(curl -fsS "$api/check-runs?per_page=100" 2>/dev/null) &&
    statuses=$(curl -fsS "$api/status" 2>/dev/null); then
    printf '%s\n%s\n' "$runs" "$statuses" | jq -rs '
      [(.[0].check_runs[] | {__typename: "CheckRun", status: (.status | ascii_upcase),
          conclusion: ((.conclusion // "") | ascii_upcase)}),
       (.[1].statuses[] | {__typename: "StatusContext", state: (.state | ascii_upcase)})] |
      '"$verdict"
  else
    echo unknown
  fi
}

# No checks on a PR is fine in a repo without CI, and means "not started yet"
# in one with it, as right after a push.
has_ci=""
if [[ -n $(git ls-tree -d --name-only "$base" .github/workflows) ]]; then
  has_ci=1
fi

# --- git: conflicts with the default branch, then with each other ----------

declare -A tree_of=() files_of=() ready=()
for b in "${branches[@]}"; do
  files_of[$b]=$(git diff --name-only "$base...$b" | sort)
  # The tree main would have with this branch merged, kept for the pairs.
  if out=$(git merge-tree --write-tree "$base" "$b" 2>/dev/null); then
    tree_of[$b]=${out%%$'\n'*}
  fi
done

# Each pair once. Both branches are first merged into the default branch, and
# the results merged with it as the base: a conflict here is one that appears
# when the second merges after the first, not one between how far behind the
# two are. A branch that conflicts with the default branch is left out; it
# needs a rebase first, which is said above it.
declare -A shared=() clash=()
for ((i = 0; i < ${#branches[@]}; i++)); do
  b=${branches[i]}
  for ((j = i + 1; j < ${#branches[@]}; j++)); do
    o=${branches[j]}
    s=$(comm -12 <(echo "${files_of[$b]}") <(echo "${files_of[$o]}") | paste -sd ' ')
    [[ -n $s ]] || continue
    shared[$b|$o]=$s
    shared[$o|$b]=$s
    if [[ -n ${tree_of[$b]-} && -n ${tree_of[$o]-} ]] &&
      ! git merge-tree --write-tree --quiet --merge-base="$base" \
        "${tree_of[$b]}" "${tree_of[$o]}" >/dev/null 2>&1; then
      clash[$b|$o]=1
      clash[$o|$b]=1
    fi
  done
done

# --- report ----------------------------------------------------------------

for b in "${branches[@]}"; do
  task=$(task_of "$b")
  path=${wt_of[$b]-}

  if [[ $task != "$b" ]]; then
    echo "$b  (task $task)"
  else
    echo "$b"
  fi

  line="  ${ahead_of[$b]} ahead, ${behind_of[$b]} behind $default"
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

  state=${state_of[$b]}
  checks=""
  unpublished=""
  head=${remote_name[$b]}
  if [[ -z $github ]]; then
    echo "  $handoff"
  elif [[ $state == unknown ]]; then
    echo "  $handoff, PR unknown (GitHub did not answer)"
  elif [[ $state == none ]]; then
    echo "  $handoff, no PR"
  else
    line="  $handoff, PR #${pr_num[$head]} $state"
    if [[ $state == open ]]; then
      checks=$(checks_of "${pr_num[$head]}" "${pr_sha[$head]}")
      if [[ $checks == none ]]; then
        if [[ -n $has_ci ]]; then
          line+=", no checks reported yet"
        else
          line+=", no CI"
        fi
      else
        line+=", checks $checks"
      fi
      if [[ ${pr_sha[$head]} != "$(git rev-parse "$b")" ]]; then
        unpublished=1
        line+=", local commits not published (run pr-handoff)"
      fi
    elif [[ $state == merged ]]; then
      line+="; nothing left to do but delete the branch"
    fi
    echo "$line"
  fi

  if [[ $state != merged ]]; then
    if [[ -n ${tree_of[$b]-} ]]; then
      echo "  merges cleanly into $default"
    else
      echo "  CONFLICTS with $default, rebase first"
    fi
    for o in "${branches[@]}"; do
      [[ -n ${shared[$b|$o]-} && ${state_of[$o]-} != merged ]] || continue
      if [[ -n ${clash[$b|$o]-} ]]; then
        echo "  CONFLICTS with $o in ${shared[$b|$o]}"
      else
        echo "  shares ${shared[$b|$o]} with $o"
      fi
    done
  fi

  # Ready: the PR is open, shows exactly this branch, and its checks passed,
  # or there is no CI to wait for.
  if [[ -n ${tree_of[$b]-} && $state == open && -z $unpublished ]] &&
    [[ $checks == passed || ($checks == none && -z $has_ci) ]]; then
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
    if [[ -z $github ]]; then
      echo "Next in order is $b. Without GitHub, whether it is ready is unknown."
    elif [[ -n ${ready[$b]-} ]]; then
      echo "Next: merge $b."
    else
      echo "Next in order is $b, which is not ready yet."
    fi
    break
  done
elif [[ -n $github ]]; then
  # No plan. A ready branch that shares no file with another open branch
  # changes nothing for the rest when it merges, so those go first, in any
  # order. One that shares a file can change what the others conflict with.
  independent=() entangled=()
  for b in "${branches[@]}"; do
    [[ -n ${ready[$b]-} ]] || continue
    alone=1
    for o in "${branches[@]}"; do
      if [[ -n ${shared[$b|$o]-} && ${state_of[$o]} != merged ]]; then
        alone=""
      fi
    done
    if [[ -n $alone ]]; then
      independent+=("$b")
    else
      entangled+=("$b")
    fi
  done
  if [[ $((${#independent[@]} + ${#entangled[@]})) -eq 0 ]]; then
    echo "Nothing is ready to merge: no open PR, up to date with its branch and passing checks, that merges cleanly."
  else
    if [[ ${#independent[@]} -gt 0 ]]; then
      echo "Ready, and touching no other open branch's files (any order):"
      printf '  %s\n' "${independent[@]}"
    fi
    if [[ ${#entangled[@]} -gt 0 ]]; then
      echo "Ready, but sharing files with another open branch (one at a time):"
      printf '  %s\n' "${entangled[@]}"
    fi
    echo "After each merge, run this again: conflicts can change."
  fi
fi
