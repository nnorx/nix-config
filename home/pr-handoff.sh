# Publishes a PR that Claude Code prepared but cannot push. See
# home/pr-handoff.nix. Built with writeShellApplication, which adds the
# shebang, errexit, nounset and pipefail.

usage() {
  cat >&2 <<'EOF'
usage: pr-handoff [--base <branch>] [--force-with-lease]
           push this branch and open its PR, or update the open one
       pr-handoff merge <number>
           squash-merge a PR with its prepared message, then delete the branch
       pr-handoff gitlens [<base>]
           open what this branch adds since it left <base>, the default
           branch unless given, in GitLens
EOF
  exit 64
}

die() {
  echo "pr-handoff: $*" >&2
  exit 1
}

# confirm <question> <base branch> <head commit> <diff command...>: yes or no.
# `d` pages through the change in full before asking again, and `g` opens it
# in GitLens, where it is easier to move between files. The summary above the
# question is enough for a docs fix, not for code going out under Nick's name.
confirm() {
  local question=$1 into=$2 tip=$3 reply
  shift 3
  while :; do
    read -r -p "$question [y/N/d=diff/g=GitLens] " reply </dev/tty
    case $reply in
      [yY] | [yY][eE][sS]) return 0 ;;
      # Quitting less early ends the diff with SIGPIPE, which is not a failure.
      [dD]) "$@" | less -R || true ;;
      [gG]) gitlens "$into" "$tip" || true ;;
      *) return 1 ;;
    esac
  done
}

# gitlens <base branch> <head commit>: opens what the head adds since it left
# origin/<base> in GitLens's Search & Compare view, in the VS Code window
# already open, through the extension's own link format. The left side is the
# merge base, so this is the PR's three-dot diff. path= names the main
# checkout, which GitLens matches before anything else; a worktree shares its
# refs, so the comparison is the same from either. Returns rather than dies:
# at a prompt, a failure here should not abandon the publish or merge.
gitlens() {
  local from to repo
  command -v code >/dev/null || {
    echo "pr-handoff: no code on PATH to open GitLens with" >&2
    return 1
  }
  git fetch --quiet origin "$1" || return 1
  # A PR's head may exist only on GitHub, when merging from another clone.
  git cat-file -e "$2^{commit}" 2>/dev/null || git fetch --quiet origin "$2" || return 1
  from=$(git merge-base "origin/$1" "$2") || return 1
  to=$(git rev-parse "$2^{commit}") || return 1
  repo=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
  # forge's code passes Wayland flags that its CLI warns about on every call.
  code --open-url "vscode://eamodio.gitlens/link/r/-/compare/$from...$to?path=$repo" 2>&1 |
    grep -v "is not in the list of known options" >&2 || true
}

# From GitHub in an agent's worktree: refs/remotes/origin/HEAD is in the
# repository's shared refs, which commands in the sandbox can write, and an
# agent that pointed it elsewhere would change what this compares against.
default_branch() {
  local ref
  if ! agent_worktree && ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD); then
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

# What looks like an IP or MAC address. lib/net.nix's own addresses are
# public and match too, so a hit is a reason to look, not to refuse.
address='\b([0-9]{1,3}\.){3}[0-9]{1,3}\b|\b([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b'

# An agent's worktree, as `claude --bg -w` and the night shift make them:
# everything in it was written by an agent.
agent_worktree() {
  [[ $(git rev-parse --show-toplevel) == */.claude/worktrees/* ]]
}

# Files the branch changes that run on Nick's machine once he works in the
# checkout, rather than on GitHub's: hooks, build and test setup, editor and
# environment config. Shown before the question, so a review starts there.
# More patterns, extended regular expressions on the path, from the
# repository's git config: `git config --add pr-handoff.watch '^ci/local/'`.
WATCHED='(^|/)(\.husky|\.githooks|scripts|\.claude|\.vscode|\.github/workflows)/|(^|/)(Makefile|[^/]*\.mk|pyproject\.toml|package\.json|\.yarnrc\.yml|\.envrc|flake\.nix|\.pre-commit-config\.yaml)$'
watched() {
  local extra
  extra=$(git config --get-all pr-handoff.watch | paste -sd '|' || true)
  git diff --name-only "$1" | grep -E "$WATCHED${extra:+|$extra}" || true
}

# lfsconfig_moved <base>: whether the .lfsconfig git-lfs would read here
# differs from origin/<base>'s, which the fetch in publish has just set.
# git-lfs reads it from the working tree, else the index, else HEAD, and it
# says where LFS objects go (lfs.url, lfs.pushurl). In an agent's worktree it
# can be untracked, which neither the diff nor the uncommitted check shows,
# and `git lfs push` would then upload the branch's objects wherever the
# agent pointed. --no-filters: the bytes git-lfs reads, not what a
# .gitattributes rule would make of them.
lfsconfig_moved() {
  local top ours theirs
  top=$(git rev-parse --show-toplevel)
  if [[ -e $top/.lfsconfig || -L $top/.lfsconfig ]]; then
    ours=$(git hash-object --no-filters -- "$top/.lfsconfig" 2>/dev/null) || return 0
  else
    ours=$(git rev-parse --quiet --verify ":.lfsconfig" || git rev-parse --quiet --verify "HEAD:.lfsconfig" || true)
  fi
  theirs=$(git rev-parse --quiet --verify "origin/$1:.lfsconfig" || true)
  [[ $ours != "$theirs" ]]
}

# What the review below is for: the PR is public, and this runs as Nick.
show() {
  echo "--- title"
  echo "$head"
  echo "--- body"
  cat "$body"
  echo "---"
  local hits
  hits=$({ echo "$head"; cat "$body"; } | grep -nE "$address" || true)
  if [[ -n $hits ]]; then
    echo "!! These lines look like an IP or MAC address:"
    echo "$hits"
  fi
}

# show_commits <range>: the same check over each commit message in <range>.
# A branch's commits stay listed on its PR after the squash merge, so their
# messages are published with it. Each hit is <commit>:<line>:<text>.
show_commits() {
  local hits
  hits=$(git rev-list --reverse "$1" | while read -r c; do
    git show -s --format=%B "$c" | grep -nE "$address" | sed "s/^/${c:0:7}:/" || true
  done)
  if [[ -n $hits ]]; then
    echo "!! These commit message lines look like an IP or MAC address:"
    echo "$hits"
  fi
}

publish() {
  local base="" force=() branch number="" state="" pr_base="" action tip now
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
  # The commit the review is of, and the one pushed: an agent still at work
  # in its worktree could commit while the question waits, and that commit
  # must not go out unread, as `merge` holds GitHub to its head.
  tip=$(git rev-parse HEAD)
  [[ $(git rev-list --count "origin/$base..$tip") -gt 0 ]] ||
    die "$branch has no commits beyond origin/$base"

  echo "Branch: $branch -> $base ($action)"
  git log --oneline "origin/$base..$tip"
  git diff --stat "origin/$base...$tip" | tail -n 1
  if [[ -n $(git status --porcelain --untracked-files=no) ]]; then
    echo "!! Uncommitted changes, which will not be pushed."
  fi
  if agent_worktree; then
    local touched line
    ! lfsconfig_moved "$base" ||
      die "the .lfsconfig here is not origin/$base's, and it decides where LFS objects are pushed; read it, and remove it or publish by hand"
    touched=$(watched "origin/$base...$tip")
    if [[ -n $touched ]]; then
      echo "!! An agent changed files that run code on this machine; read these first:"
      while IFS= read -r line; do echo "     $line"; done <<<"$touched"
    fi
  fi
  show
  show_commits "origin/$base..$tip"
  confirm "Push $branch and $action?" "$base" "$tip" \
    git diff --color=always "origin/$base...$tip" ||
    die "nothing published"

  now=$(git rev-parse HEAD)
  [[ $now == "$tip" ]] ||
    die "nothing published: $branch moved from ${tip:0:7} to ${now:0:7} during the review." \
      "Run pr-handoff again to review the new head."

  # With hooks off in an agent's worktree (below), the pre-push hook that
  # uploads a repository's LFS objects does not run, so this does. The
  # .lfsconfig is checked again first: one the agent left during the review
  # would otherwise choose where they go.
  if agent_worktree && git lfs env >/dev/null 2>&1 &&
    git grep -q -e 'filter=lfs' "$tip" -- ':(top,glob)**/.gitattributes'; then
    ! lfsconfig_moved "$base" ||
      die "nothing published: an .lfsconfig that is not origin/$base's appeared during the review"
    git lfs push origin "$tip"
  fi
  # By commit, not by name, so nothing that lands on the branch now goes too.
  # -u sets no upstream for a commit, so that is set after.
  git push "${force[@]}" origin "$tip:refs/heads/$branch"
  git branch --quiet --set-upstream-to "origin/$branch" "$branch" || true
  if [[ -n $number ]]; then
    gh pr edit "$number" --title "$head" --body-file "$body" >/dev/null
    gh pr view "$number" --json url -q .url
  else
    gh pr create --base "$base" --head "$branch" --title "$head" --body-file "$body"
  fi
}

merge() {
  [[ $# -eq 1 && $1 =~ ^[0-9]+$ ]] || usage
  local n=$1 info state branch base tip now
  info=$(gh pr view "$n" --json state,headRefName,baseRefName,headRefOid \
    -q '"\(.state) \(.headRefName) \(.baseRefName) \(.headRefOid)"')
  read -r state branch base tip <<<"$info"
  [[ $state == OPEN ]] || die "#$n is $state"
  read_handoff "$dir/$branch.squash.md"
  [[ $head == *"(#$n)" ]] || head="$head (#$n)"

  echo "PR: #$n $branch -> $base"
  gh pr checks "$n" || echo "!! Not every check has passed."
  show
  # GitHub's diff of the PR, which is what merges, whatever is checked out here.
  confirm "Squash-merge #$n into $base and delete $branch?" "$base" "$tip" \
    gh pr diff "$n" --color=always ||
    die "nothing merged"

  # Only the head read above, which the review was of. Merging deploys the
  # Pis that night, so a push to the branch since then must not ride along.
  if ! gh pr merge "$n" --squash --delete-branch --match-head-commit "$tip" \
    --subject "$head" --body-file "$body"; then
    now=$(gh pr view "$n" --json headRefOid -q .headRefOid) || now=$tip
    [[ $now == "$tip" ]] ||
      die "nothing merged: $branch moved from ${tip:0:7} to ${now:0:7} during the review." \
        "Run pr-handoff merge $n again to review the new head."
    die "nothing merged"
  fi
  rm -f "$dir/$branch.md" "$dir/$branch.squash.md"
}

# The review prints straight to the terminal. A pager would stop it halfway.
export GIT_PAGER=cat GH_PAGER=cat

# No git hook runs from an agent's worktree, for any command here, git's or
# gh's. A repository's core.hooksPath is often relative, husky's .husky/_ say,
# which in a worktree means the worktree's own copy: the agent's to write,
# from a sandbox, and run here with Nick's login. `git push --no-verify` would
# skip only pre-push, not reference-transaction or the rest. The checks those
# hooks run, the agent ran in its sandbox, and CI runs again. forge empties
# hooksPath for every repository (home/claude.nix); this covers the Mac.
if agent_worktree 2>/dev/null; then
  n=${GIT_CONFIG_COUNT:-0}
  export "GIT_CONFIG_KEY_$n=core.hooksPath" "GIT_CONFIG_VALUE_$n=/dev/null" GIT_CONFIG_COUNT=$((n + 1))
fi

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
  gitlens)
    [[ $# -le 2 ]] || usage
    gitlens "${2:-$(default_branch)}" HEAD
    ;;
  -h | --help) usage ;;
  *) publish "$@" ;;
esac
