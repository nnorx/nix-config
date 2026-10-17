# Every check a change needs, in one command, and the one CI runs. Built by
# flake.nix as `apps.<system>.preflight` with writeShellApplication, which adds
# the shebang, errexit, nounset and pipefail. PREFLIGHT_EVAL and
# PREFLIGHT_BRIEF name preflight-eval.nix and preflight-brief.jq in the store.
#
#   1. The brief's rules, against the hand-written cases in
#      tests/preflight-brief/ (scripts/test-preflight-brief.sh). A slip in a
#      rule changes verdicts with no error, so this fails the run instead.
#      First, since it takes milliseconds.
#   2. The night-shift dispatcher, pkgs/night-shift/night-shift.sh, against
#      stubbed Linear, GitHub, ntfy and Claude (tests/night-shift/run.sh). It runs
#      unattended, acts as Nick in Linear and deletes worktrees and branches,
#      and nothing else checks its guards once a change lands. Second, since
#      it needs no evaluation and takes seconds, so a broken guard shows
#      before the minutes the steps below take. Then fleet-deploy,
#      home/fleet-deploy.sh, against stubbed hosts, nix and cache
#      (tests/fleet-deploy/run.sh), for the same reasons: it deploys the Pis.
#   3. `nix flake check --all-systems --no-build`. --all-systems, or nix skips
#      the aarch64 hosts on an x86 machine; --no-build, so this stays an
#      evaluation and never a multi-hour Pi kernel build.
#   4. Every host's toplevel and every Home Manager config, evaluated. flake
#      check alone does neither: it passes a host whose toplevel cannot
#      evaluate (a missing sops file did exactly that), and it skips
#      homeConfigurations, so a broken WSL or macOS profile looked green.
#      The change and its base are evaluated at once, as two nix processes,
#      since each is single-threaded and neither needs the other. flake check
#      runs before them, not beside them: it alone peaks near 12 GB, and all
#      three at once passed 18 GB on forge, more than a 16 GB GitHub runner
#      has. Each evaluation's time and peak memory follow its output.
#   5. The brief: which of them the change actually touches, against a base,
#      by default where this branch left origin/main, and for each host what
#      kind of change it gets (scripts/preflight-brief.jq). That answers
#      whether merging changes the Pis, which upgrade from main the same
#      night, and whether that needs Nick at hand. It is advice and never
#      fails the run.
#   6. Formatting, as CI checks it. Last, so a formatting slip never hides an
#      evaluation error or the brief above. Files that were not formatted get
#      formatted, and the run fails so the change is looked at.
#
# --head <rev> checks a commit instead of the working tree, so a branch can be
# briefed without checking it out; formatting is then skipped, since it works
# on files. --json <file> also writes the brief as JSON, for tools that act on
# the verdict.
#
# --flake-check skip leaves out step 3, and --flake-check only runs it alone.
# CI uses them to run flake check on a runner of its own, beside the rest:
# in a row the two are most of preflight's time, and flake check's 12 GB
# cannot share a 16 GB runner with the evaluations (check.yml).
#
# Uses the nix on PATH rather than one of its own, so it talks to the daemon in
# the way everything else on the machine does.

usage() {
  echo "usage: preflight [--base <rev>] [--head <rev>] [--json <file>] [--flake-check skip|only]" >&2
  exit 64
}

base=""
head=""
json=""
flake_check=run
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || usage
  case $1 in
    --base) base=$2 ;;
    --head) head=$2 ;;
    --json) json=$2 ;;
    --flake-check)
      [[ $2 == skip || $2 == only ]] || usage
      flake_check=$2
      ;;
    *) usage ;;
  esac
  shift 2
done
# Alone, flake check writes no brief.
[[ $flake_check != only || -z $json ]] || usage
# Before the cd below, so a relative path means what it did to the caller.
[[ -z $json ]] || json=$(realpath -m -- "$json")

root=$(git rev-parse --show-toplevel)
cd "$root"

step() {
  echo
  echo "==> $*"
}

if [[ -n $head ]]; then
  head=$(git rev-parse --verify "$head^{commit}")
  ref="git+file://$root?rev=$head"
else
  ref="git+file://$root"
fi

# Alone, flake check compares with nothing.
if [[ $flake_check != only && -z $base ]]; then
  base=$(git merge-base "${head:-HEAD}" origin/main) ||
    {
      echo "preflight: no merge-base with origin/main; fetch it, or pass --base" >&2
      exit 1
    }
  # On main itself, clean and level with origin/main, the comparison would be
  # a commit with itself, and the question worth asking is what the last
  # commit changed. Anywhere else, HEAD as the base is the honest answer: a
  # fresh branch with nothing on it changes nothing.
  if [[ -z $head && $(git symbolic-ref --quiet --short HEAD || true) == main &&
    $base == "$(git rev-parse HEAD)" ]] && git diff --quiet HEAD; then
    base=$(git rev-parse --verify --quiet 'HEAD^') || base=$(git rev-parse HEAD)
  fi
  # The same for --head naming main, or any commit already on it.
  if [[ -n $head && $base == "$head" ]]; then
    base=$(git rev-parse --verify --quiet "$head^") || base=$head
  fi
fi
[[ $flake_check == only ]] || base=$(git rev-parse --verify "$base^{commit}")

# The flake sees only what git tracks, so a new file that was never added is
# silently absent from every evaluation below.
untracked=$(git ls-files --others --exclude-standard)
if [[ -z $head && -n $untracked ]]; then
  echo "!! Untracked, so invisible to the flake until \`git add\`:"
  while IFS= read -r path; do echo "   $path"; done <<<"$untracked"
fi

if [[ $flake_check != only ]]; then
  step "brief rules"
  # Under --head too: the brief below uses the rules this preflight was built
  # with (PREFLIGHT_BRIEF), not the commit's, and those are what this tests.
  # $BASH, since writeShellApplication puts no bash on PATH.
  "$BASH" scripts/test-preflight-brief.sh

  step "night-shift dispatcher"
  # From the checkout under --head too: the working tree's dispatcher, not the
  # commit's.
  "$BASH" tests/night-shift/run.sh

  step "fleet-deploy"
  "$BASH" tests/fleet-deploy/run.sh
fi

work=$(mktemp -d)
# The evaluations below run in the background, each in a process group of its
# own (set -m), so one kill stops nix along with the time wrapping it, and no
# nix outlives a run that fails or is stopped: the night shift's bwrap and
# CI's step both expect that. INT and TERM become exits, so the trap runs for
# them too.
bg=()
cleanup() {
  for pid in "${bg[@]}"; do kill -- "-$pid" 2>/dev/null || true; done
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Wall time and peak memory of a nix process, from GNU time (in runtimeInputs,
# since a runner need not have it), so the log says how close a run came to
# the runner's memory.
timed() {
  local name=$1
  shift
  command time --quiet -f '%e %M' -o "$work/$name.time" "$@"
}
peak() {
  local label=${2:-$1}
  [[ -s $work/$1.time ]] || return 0
  awk -v name="$label" '{ printf "   %s: %.0f s, peak %.1f GB\n", name, $1, $2 / 1048576 }' "$work/$1.time"
}

if [[ $flake_check != skip ]]; then
  step "flake check"
  timed flake-check nix flake check --all-systems --no-build "$ref"
  peak flake-check "flake check"
fi
[[ $flake_check != only ]] || exit 0

evaluate() {
  timed "$2" nix eval --impure --json --expr "import $PREFLIGHT_EVAL { ref = \"$1\"; }" \
    </dev/null >"$work/$2.json" 2>"$work/$2.err"
}

step "evaluate every host and home config, and compare with ${base:0:12}"
set -m
evaluate "$ref" head &
bg+=("$!")
evaluate "git+file://$root?rev=$base" base &
bg+=("$!")
set +m

# The change failing to evaluate fails the run with nix's error, as it did in
# the foreground. Each status comes from `wait <pid>`; a bare wait drops them.
status=0
wait "${bg[0]}" || status=$?
cat "$work/head.err" >&2
((status == 0)) || exit "$status"
peak head

# The base failing to evaluate is not this change's fault, and says nothing
# about it, so the run goes on. But the comparison is then unknown, not "new",
# and the brief says so rather than flagging every host.
base_ok=true
wait "${bg[1]}" || base_ok=false
bg=()
peak base
if ! $base_ok; then
  echo '{"hosts": {}, "homes": {}}' >"$work/base.json"
  echo "!! The base did not evaluate, so what this changes is unknown. Its error ends:"
  tail -n 15 "$work/base.err" | sed 's/^/   /'
fi

# Package name -> versions in a derivation's closure. That is the build
# closure, compilers included, but reading it needs nothing built, only the
# .drv files evaluation already wrote. Newer nix wraps the output of `derivation
# show` in {derivations, version}, and keeps structured attributes apart.
closure_versions() {
  nix derivation show --recursive "$1" | jq -c '
    (.derivations // .)
    | [.[] | (.structuredAttrs // (.env.__json | fromjson?) // .env // {})
        | select(.pname? and .version?) | [.pname, .version]]
    | group_by(.[0]) | map({key: .[0][0], value: map(.[1]) | unique}) | from_entries'
}

# For each host the change touches, both sides' versions, so the brief can say
# which packages move.
echo '{}' >"$work/versions.json"
if $base_ok; then
  jq -rn --slurpfile b "$work/base.json" --slurpfile h "$work/head.json" '
    $h[0].hosts | keys[]
    | select(. as $k | ($b[0].hosts[$k].drv // null) as $d | $d != null and $d != $h[0].hosts[$k].drv)' |
    while IFS= read -r host; do
      for side in base head; do
        closure_versions "$(jq -r --arg h "$host" '.hosts[$h].drv' "$work/$side.json")" >"$work/$side-$host.json"
      done
      jq --arg h "$host" --slurpfile b "$work/base-$host.json" --slurpfile n "$work/head-$host.json" \
        '.[$h] = {base: $b[0], head: $n[0]}' "$work/versions.json" >"$work/versions.next"
      mv "$work/versions.next" "$work/versions.json"
    done
fi

if [[ -n $head ]]; then
  git diff --name-only "$base" "$head"
else
  git diff --name-only "$base"
fi | jq -Rsc 'split("\n") | map(select(. != ""))' >"$work/files.json"

# One object on stdin, since a side's facts outgrow a command-line argument.
jq -n --slurpfile head "$work/head.json" --slurpfile base "$work/base.json" \
  --slurpfile files "$work/files.json" --slurpfile versions "$work/versions.json" \
  --argjson ok "$base_ok" --arg rev "${base:0:12}" \
  '{head: $head[0], base: $base[0], ok: $ok, files: $files[0], versions: $versions[0], rev: $rev}' \
  >"$work/brief-input.json"

brief() {
  jq -r --arg format "$1" -f "$PREFLIGHT_BRIEF" "$work/brief-input.json"
}

echo
brief text
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
  brief md >>"$GITHUB_STEP_SUMMARY"
fi
if [[ -n $json ]]; then
  brief json >"$json"
fi

if [[ -n $head ]]; then
  step "format: skipped, since --head checks a commit and formatting works on files"
else
  step "format"
  nix fmt -- --ci .
fi
