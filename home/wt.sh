# wt: cd into an agent's worktree, picked with fzf.
#
# Background agents (`claude --bg -w`) and the night shift both put their
# worktrees in ~/projects/<repo>/.claude/worktrees/<name>, a path too long to
# type several times a day. `wt` lists them newest first as <repo>/<name>;
# `wt <query>` jumps straight to the only match, and does nothing when none
# matches. It only changes directory: worktrees come and go with `claude rm`
# and the night shift's cleanup.
#
# Sourced by both zsh and bash (home/dev-tools.nix), so it sticks to what the
# two share, and to ls -t, which macOS's ls has too.

wt() {
  local trees opts sel d name repo had_nullglob=
  if [ -n "${ZSH_VERSION-}" ]; then
    setopt local_options null_glob
  else
    shopt -q nullglob && had_nullglob=1
    shopt -s nullglob
  fi
  trees=("$HOME"/projects/*/.claude/worktrees/*/)
  [ -n "${ZSH_VERSION-}" ] || [ -n "$had_nullglob" ] || shopt -u nullglob

  if [ "${#trees[@]}" -eq 0 ]; then
    echo "no worktrees under ~/projects/*/.claude/worktrees" >&2
    return 1
  fi

  opts=()
  if [ "$#" -gt 0 ]; then
    opts=(--query "$*" --select-1 --exit-0)
  fi

  # fzf searches and shows only the first field, so a query matches the
  # repo and worktree name rather than the home directory's path.
  # ls -t is the sort by mtime that GNU and macOS share, and worktree names
  # come from branch names, which hold no newlines.
  # shellcheck disable=SC2012
  sel=$(
    ls -dt -- "${trees[@]}" | while IFS= read -r d; do
      d=${d%/}
      name=${d##*/}
      repo=${d%/.claude/worktrees/*}
      repo=${repo##*/}
      printf '%s/%s\t%s\n' "$repo" "$name" "$d"
    done | fzf --delimiter '\t' --with-nth 1 \
      --preview 'git -C {2} log --oneline -3' \
      "${opts[@]}"
  ) || return 1
  cd -- "${sel#*$'\t'}" || return 1
}
