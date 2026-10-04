# Publishes a PR that Claude Code prepared but cannot push. See
# home/pr-handoff.nix. Built with writeShellApplication, which adds the
# shebang, errexit, nounset and pipefail.

usage() {
  cat >&2 <<'EOF'
usage: pr-handoff [--base <branch>] [--force-with-lease]
           push this branch and open its PR, or update the open one
       pr-handoff merge <number>
           squash-merge a PR with its prepared message, then delete the branch
EOF
  exit 64
}

die() {
  echo "pr-handoff: $*" >&2
  exit 1
}

confirm() {
  local reply
  read -r -p "$1 [y/N] " reply </dev/tty
  [[ $reply == [yY] || $reply == [yY][eE][sS] ]]
}

default_branch() {
  local ref
  if ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD); then
    echo "${ref#origin/}"
  else
    gh repo view --json defaultBranchRef -q .defaultBranchRef.name
  fi
}

# The first line is the title or subject. The rest, less its leading blank
# lines, goes to $body. Never evaluated: it reaches gh as an argument and a
# file, so nothing Claude writes can make this do more than publish it.
read_handoff() {
  [[ -s $1 ]] || die "no handoff at $1; ask Claude to write one"
  head=$(head -n 1 "$1")
  [[ -n $head ]] || die "the first line of $1, the title, is empty"
  tail -n +2 "$1" | sed '/./,$!d' >"$body"
}

# What the review below is for: the PR is public, and this runs as Nick.
show() {
  echo "--- title"
  echo "$head"
  echo "--- body"
  cat "$body"
  echo "---"
  local hits
  hits=$({ echo "$head"; cat "$body"; } |
    grep -nE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b|\b([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b' || true)
  if [[ -n $hits ]]; then
    echo "!! These lines look like an IP or MAC address:"
    echo "$hits"
  fi
}

publish() {
  local base="" force=() branch number="" state="" pr_base="" action
  while [[ $# -gt 0 ]]; do
    case $1 in
      --base)
        [[ $# -ge 2 ]] || usage
        base=$2
        shift 2
        ;;
      --force-with-lease)
        force=(--force-with-lease)
        shift
        ;;
      *) usage ;;
    esac
  done

  branch=$(git symbolic-ref --quiet --short HEAD) || die "not on a branch"
  [[ $branch != "$(default_branch)" ]] || die "on $branch; publish from a feature branch"
  read_handoff "$dir/$branch.md"

  # gh finds the newest PR from this branch, which may be closed or merged.
  if info=$(gh pr view "$branch" --json number,state,baseRefName \
    -q '"\(.number) \(.state) \(.baseRefName)"' 2>/dev/null); then
    read -r number state pr_base <<<"$info"
  fi
  if [[ $state == OPEN ]]; then
    action="update #$number"
    [[ -z $base || $base == "$pr_base" ]] ||
      die "#$number is based on $pr_base, not $base; change that on GitHub"
    base=$pr_base
  else
    action="open a PR"
    number=""
    base=${base:-$(default_branch)}
  fi

  git fetch --quiet origin "$base"
  [[ $(git rev-list --count "origin/$base..HEAD") -gt 0 ]] ||
    die "$branch has no commits beyond origin/$base"

  echo "Branch: $branch -> $base ($action)"
  git log --oneline "origin/$base..HEAD"
  git diff --stat "origin/$base...HEAD" | tail -n 1
  if [[ -n $(git status --porcelain --untracked-files=no) ]]; then
    echo "!! Uncommitted changes, which will not be pushed."
  fi
  show
  confirm "Push $branch and $action?" || die "nothing published"

  git push "${force[@]}" -u origin "$branch"
  if [[ -n $number ]]; then
    gh pr edit "$number" --title "$head" --body-file "$body" >/dev/null
    gh pr view "$number" --json url -q .url
  else
    gh pr create --base "$base" --head "$branch" --title "$head" --body-file "$body"
  fi
}

merge() {
  [[ $# -eq 1 && $1 =~ ^[0-9]+$ ]] || usage
  local n=$1 info state branch base
  info=$(gh pr view "$n" --json state,headRefName,baseRefName \
    -q '"\(.state) \(.headRefName) \(.baseRefName)"')
  read -r state branch base <<<"$info"
  [[ $state == OPEN ]] || die "#$n is $state"
  read_handoff "$dir/$branch.squash.md"
  [[ $head == *"(#$n)" ]] || head="$head (#$n)"

  echo "PR: #$n $branch -> $base"
  gh pr checks "$n" || echo "!! Not every check has passed."
  show
  confirm "Squash-merge #$n into $base and delete $branch?" || die "nothing merged"

  gh pr merge "$n" --squash --delete-branch --subject "$head" --body-file "$body"
  rm -f "$dir/$branch.md" "$dir/$branch.squash.md"
}

# The review prints straight to the terminal. A pager would stop it halfway.
export GIT_PAGER=cat GH_PAGER=cat

# Under the common dir, so every worktree shares one place and nothing here is
# ever committed. Commands in Claude's sandbox can write there.
dir="$(git rev-parse --path-format=absolute --git-common-dir)/pr-handoff"
head=""
body=$(mktemp)
trap 'rm -f "$body"' EXIT

case ${1-} in
  merge)
    shift
    merge "$@"
    ;;
  -h | --help) usage ;;
  *) publish "$@" ;;
esac
