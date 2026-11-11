# wt: pick a branch with fzf and go where it lives.
#
# A branch checked out somewhere (the main checkout, an agent's worktree, a
# scratch worktree in /tmp) means cd there, since git refuses to check one
# branch out twice. Any other branch is switched to in its repo's main
# checkout. `wt <query>` jumps straight to the only match.
#
# It lists the local branches of the repo you are in and of every repo
# directly under the directories in WT_ROOTS (colon-separated, default
# ~/projects), newest commit first. Sourced by both zsh and bash
# (home/dev-tools.nix), so it sticks to what the two share.

_wt_repos() {
  local root d top IFS=:
  if [ -n "${ZSH_VERSION-}" ]; then
    setopt local_options null_glob sh_word_split
  else
    shopt -s nullglob # wt runs this in a subshell
  fi
  top=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
    printf '%s\n' "${top%/.git}"
  for root in ${WT_ROOTS:-$HOME/projects}; do
    for d in "$root"/*/; do
      # A .git file is a linked worktree or a submodule.
      [ -d "$d.git" ] && printf '%s\n' "${d%/}"
    done
  done
}

wt() {
  local opts=() sel repo branch dir
  [ "$#" -gt 0 ] && opts=(--query "$*" --select-1 --exit-0)

  # Rows are label, repo, branch, then where the branch is checked out,
  # shortened and in full. Those two can be empty, so they go last: read
  # collapses adjacent tabs. (Not "path": zsh ties that name to PATH.)
  sel=$(
    (_wt_repos) | awk '!seen[$0]++' | while IFS= read -r repo; do
      git -C "$repo" for-each-ref refs/heads \
        --format='%(committerdate:unix)%09%(refname:short)%09%(worktreepath)' |
        awk -F '\t' -v OFS='\t' -v repo="$repo" -v home="$HOME" '{
          n = split(repo, p, "/"); shown = $3
          if (index(shown, home "/") == 1) shown = "~" substr(shown, length(home) + 1)
          print $1, p[n] "/" $2, repo, $2, shown, $3
        }'
    done | sort -rn | cut -f2- |
      fzf --exact --delimiter '\t' --with-nth 1,4 --nth 1 \
        --preview 'git -C {2} log --oneline -5 {3} --' \
        "${opts[@]}"
  ) || return 1

  IFS=$'\t' read -r _ repo branch _ dir <<<"$sel"
  if [ -n "$dir" ]; then
    cd -- "$dir" || return 1
  else
    cd -- "$repo" && git switch "$branch"
  fi
}
