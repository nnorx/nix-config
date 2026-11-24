#!/usr/bin/env bash
# Runs pkgs/pr-handoff/ against stubbed gh, less and code (./stub.sh), with
# real git in temporary repositories and a bare origin on disk, and checks
# what it published. It runs as Nick on what agents wrote, and these are its
# guards: handoff links and control characters refused, one commit range
# shown and pushed, the default branch and the lease as origin answers, and
# the files that run code here named in every checkout.
# scripts/preflight-tests.sh runs it after fleet-deploy's.
#
# Answers to its prompt come through PR_HANDOFF_TTY, a line each. One line
# per case, then the failures. PR_HANDOFF_SCRIPT names the script under test,
# by default this checkout's. PR_HANDOFF_TESTS_KEEP=1 keeps every case's
# directory, with the stubs' log and the script's output.
set -euo pipefail

root=$(realpath -- "$(dirname -- "$0")/../..")
here=$root/tests/pr-handoff
script=$(realpath -- "${PR_HANDOFF_SCRIPT:-$root/pkgs/pr-handoff/src/main.ts}")

work=$(mktemp -d)
if [[ -n ${PR_HANDOFF_TESTS_KEEP:-} ]]; then
  echo "pr-handoff tests: keeping $work"
else
  trap 'rm -rf "$work"' EXIT
fi

bin=$work/bin
mkdir -p "$bin"
for tool in gh less code; do
  printf '#!%s\nexec %q %q %s "$@"\n' "$BASH" "$BASH" "$here/stub.sh" "$tool" >"$bin/$tool"
  chmod +x "$bin/$tool"
done

export GIT_CONFIG_GLOBAL=$work/gitconfig GIT_CONFIG_NOSYSTEM=1
git config --global user.name test
git config --global user.email test@example.invalid
git config --global init.defaultBranch main
seed=$work/origin.git
git init --quiet --bare "$seed"
git clone --quiet "$seed" "$work/seed" 2>/dev/null
git -C "$work/seed" commit --quiet --allow-empty -m base
git -C "$work/seed" push --quiet origin main main:other
base=$(git -C "$work/seed" rev-parse HEAD)

c="" co="" origin="" hand="" status=0
begin() {
  c=$work/$1
  co=$c/checkout
  origin=$c/origin.git
  mkdir -p "$c"
  git clone --quiet --bare "$seed" "$origin"
  git clone --quiet "$origin" "$co"
  git -C "$co" switch --quiet -c topic
  : >"$c/log"
  echo y >"$c/answers"
  hand=$(git -C "$co" rev-parse --path-format=absolute --git-common-dir)/pr-handoff
  mkdir -p "$hand"
  printf 'topic: a change\n\nWhy it changes.\n' >"$hand/topic.md"
}

# commit <file> [message]: a commit in the case's checkout that writes <file>.
commit() {
  echo "$1" >>"$co/$1"
  git -C "$co" add -- "$1"
  git -C "$co" commit --quiet -m "${2:-change $1}"
}

run() {
  status=0
  (cd "$co" && PH=$c PR_HANDOFF_TTY=$c/answers PATH=$bin:$PATH \
    node "$script" "$@") >"$c/out" 2>&1 || status=$?
}

failures=()
fail() { failures+=("$name: $*"); }
expect_status() { [[ $status == "$1" ]] || fail "exit $status, wanted $1"; }
expect_out() { grep -qF -- "$1" "$c/out" || fail "no '$1' in the output"; }
on_origin() { git -C "$origin" rev-parse --quiet --verify "refs/heads/$1" || true; }
called() { grep -q "^$1" "$c/log"; }
expect_unpublished() {
  [[ $status != 0 ]] || fail "exit 0, wanted a refusal"
  [[ -z $(on_origin topic) ]] || fail "topic was pushed"
  [[ $(on_origin main) == "$base" ]] || fail "main moved on origin"
  ! called "gh pr create" || fail "gh pr create was called"
}

case_() {
  name=$1
  local before=${#failures[@]}
  begin "$name"
  "$2"
  if [[ ${#failures[@]} == "$before" ]]; then echo "ok   $name"; else echo "FAIL $name"; fi
}

# --- Cases -------------------------------------------------------------------

t_publish() {
  commit a.txt
  local tip
  tip=$(git -C "$co" rev-parse HEAD)
  run
  expect_status 0
  [[ $(on_origin topic) == "$tip" ]] || fail "origin's topic is not the reviewed tip"
  grep -qF "gh pr create --base main --head topic --title topic: a change --body-file " "$c/log" ||
    fail "gh pr create not called with the title and body file"
  [[ $(cat "$c/body" 2>/dev/null) == "Why it changes." ]] || fail "the body file is not the handoff's body"
}

t_handoff_link() {
  commit a.txt
  mv "$hand/topic.md" "$c/hidden.md"
  ln -s "$c/hidden.md" "$hand/topic.md"
  run
  expect_unpublished
}

t_handoff_dir_link() {
  commit a.txt
  mv "$hand" "$c/elsewhere"
  ln -s "$c/elsewhere" "$hand"
  run
  expect_unpublished
}

t_body_escape() {
  commit a.txt
  printf 'topic: a change\n\nWhy \e[1A\e[2Kit changes.\n' >"$hand/topic.md"
  run
  expect_unpublished
  ! grep -q $'\e' "$c/out" || fail "the escape reached the output"
}

t_commit_escape() {
  commit a.txt $'change a.txt\e]0;title\a'
  run
  expect_unpublished
  ! grep -q $'\e' "$c/out" || fail "the escape reached the output"
}

t_branch_moves() {
  commit a.txt
  printf 'cd %q\necho b >b.txt\ngit add b.txt\ngit commit --quiet -m b\n' "$co" >"$c/on-less"
  printf 'd\ny\n' >"$c/answers"
  run
  expect_unpublished
  expect_out "moved from"
}

t_base_moves() {
  commit a.txt
  local tip
  tip=$(git -C "$co" rev-parse HEAD)
  printf 'git -C %q update-ref refs/remotes/origin/main %q\n' "$co" "$tip" >"$c/on-less"
  printf 'd\nd\ny\n' >"$c/answers"
  run
  expect_status 0
  [[ -s $c/less-1 ]] || fail "the second diff was empty"
  git -C "$co" diff "$base...$tip" | cmp -s - "$c/less-1" ||
    fail "the second diff is not of the pinned base"
  [[ $(on_origin topic) == "$tip" ]] || fail "origin's topic is not the reviewed tip"
}

t_lease() {
  commit a.txt
  git -C "$co" push --quiet origin topic
  git -C "$co" commit --quiet --amend -m amended
  local tip theirs
  tip=$(git -C "$co" rev-parse HEAD)
  theirs=$(git -C "$co" commit-tree -p HEAD -m theirs "HEAD^{tree}")
  printf 'git -C %q push --quiet --force origin %q:refs/heads/topic\n' "$co" "$theirs" >"$c/on-less"
  printf 'd\ny\n' >"$c/answers"
  run --force-with-lease
  [[ $status != 0 ]] || fail "exit 0 over a push made during the review"
  [[ $(on_origin topic) == "$theirs" ]] || fail "the push made during the review was overwritten"
  echo y >"$c/answers"
  run --force-with-lease
  expect_status 0
  [[ $(on_origin topic) == "$tip" ]] || fail "a second run did not push the tip"
}

t_head_repointed() {
  git -C "$co" switch --quiet main
  commit a.txt
  printf 'main: a change\n\nWhy.\n' >"$hand/main.md"
  git -C "$co" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/other
  run
  expect_unpublished
}

t_watched() {
  commit flake.nix
  echo n >"$c/answers"
  run
  expect_unpublished
  expect_out "read these first"
  expect_out "flake.nix"
}

t_merge_link() {
  commit a.txt
  echo "OPEN topic main $(git -C "$co" rev-parse HEAD)" >"$c/pr"
  printf 'topic: a change\n\nWhy.\n' >"$c/hidden.md"
  ln -s "$c/hidden.md" "$hand/topic.squash.md"
  run merge 7
  [[ $status != 0 ]] || fail "exit 0, wanted a refusal"
  ! called "gh pr merge" || fail "gh pr merge was called"
}

t_merge() {
  commit a.txt
  local tip
  tip=$(git -C "$co" rev-parse HEAD)
  echo "OPEN topic main $tip" >"$c/pr"
  printf 'topic: a change\n\nWhy.\n' >"$hand/topic.squash.md"
  run merge 7
  expect_status 0
  grep -qF "gh pr merge 7 --squash --delete-branch --match-head-commit $tip --subject topic: a change (#7) --body-file " "$c/log" ||
    fail "gh pr merge not called with the reviewed head and the numbered subject"
  [[ ! -e $hand/topic.md && ! -e $hand/topic.squash.md ]] || fail "the handoffs were kept"
}

# An answer cut off before its newline is no answer, as `read` has it.
t_unfinished_answer() {
  commit a.txt
  printf y >"$c/answers"
  run
  expect_unpublished
}

t_empty_title() {
  commit a.txt
  printf '\nWhy it changes.\n' >"$hand/topic.md"
  run
  expect_unpublished
  expect_out "the title, is empty"
}

# The body sits behind a gutter, so a line of it cannot pass for the frame,
# and the address in it is still flagged.
t_body_framed() {
  commit a.txt
  printf 'topic: a change\n\n✓ nothing flagged\n10.1.2.3\n' >"$hand/topic.md"
  echo n >"$c/answers"
  run
  expect_unpublished
  expect_out "│ ✓ nothing flagged"
  expect_out "!! These lines look like an IP or MAC address:"
  ! grep -q "^✓ nothing flagged" "$c/out" || fail "the body's line passed for the frame's"
}

case_ publish t_publish
case_ body-framed t_body_framed
case_ merge t_merge
case_ unfinished-answer t_unfinished_answer
case_ empty-title t_empty_title
case_ handoff-link t_handoff_link
case_ handoff-dir-link t_handoff_dir_link
case_ body-escape t_body_escape
case_ commit-escape t_commit_escape
case_ branch-moves t_branch_moves
case_ base-moves t_base_moves
case_ lease t_lease
case_ head-repointed t_head_repointed
case_ watched t_watched
case_ merge-link t_merge_link

if ((${#failures[@]} > 0)); then
  echo
  printf '%s\n' "${failures[@]}"
  exit 1
fi
