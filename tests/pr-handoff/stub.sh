# The tools pr-handoff reaches GitHub and the screen through, stood in for by
# one script: the first argument names the tool. Each call is logged to
# $PH/log. tests/pr-handoff/run.sh has the cases.
#
#   $PH/pr        what `gh pr view <number>` answers: state, head, base, head id
#   $PH/on-less   a script the first `less` runs, as if during the review
#   $PH/less-<n>  what the nth `less`, from 0, was handed
#   $PH/body      the body file `gh pr create` was handed

tool=$1
shift
printf '%s %s\n' "$tool" "$*" >>"$PH/log"

case $tool in
  code) ;;

  less)
    n=$(find "$PH" -maxdepth 1 -name 'less-*' | wc -l)
    cat >"$PH/less-$n"
    if [[ -e $PH/on-less ]]; then
      mv "$PH/on-less" "$PH/on-less.done"
      "$BASH" -euo pipefail "$PH/on-less.done"
    fi
    ;;

  gh)
    case "$1 $2" in
      "pr view")
        [[ $3 =~ ^[0-9]+$ && -e $PH/pr ]] || exit 1
        cat "$PH/pr"
        ;;
      "pr create")
        while [[ $# -gt 0 ]]; do
          [[ $1 != --body-file ]] || cp "$2" "$PH/body"
          shift
        done
        echo "https://github.invalid/pull/1"
        ;;
      "pr diff") echo "stand-in diff" ;;
      "pr checks" | "pr merge" | "pr edit") ;;
      *) exit 1 ;;
    esac
    ;;

  *) exit 1 ;;
esac
