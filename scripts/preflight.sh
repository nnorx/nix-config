# Every check a change needs, in one command, and the one CI runs. Built by
# pkgs/preflight as `apps.<system>.preflight` with writeShellApplication, which
# adds the shebang, errexit, nounset and pipefail. PREFLIGHT_* are store paths.
#
#   1, 2. The test suites, of the brief's and cve-scan's rules, the
#      night-shift dispatcher, fleet-deploy and the ratchets' exposure score
#      (scripts/preflight-tests.sh, which says why each is there).
#   3. Flake check: what `nix flake check --all-systems --no-build` evaluates,
#      less the hosts (scripts/preflight-outputs.nix). Nix keeps all it has
#      evaluated, and flake check peaked at 15.4 GB, so each piece gets a
#      process, at most 8 at once, and none passes 1.7 GB.
#   4. Every host's toplevel and every Home Manager config, evaluated: nix
#      flake check only asks that a toplevel be a derivation, and skips
#      homeConfigurations. The change and its base at once, in two nix
#      processes, each followed by its time and peak memory.
#   5. The brief: which of them the change actually touches, against a base,
#      by default where this branch left origin/main, and for each host what
#      kind of change it gets (scripts/preflight-brief.jq). That answers
#      whether merging changes the Pis, which upgrade from main the same
#      night, and whether that needs Nick at hand. It is advice and never
#      fails the run.
#   6. The ratchets (scripts/ratchets.sh): caps on prose, comment density,
#      shell length and each listening unit's systemd exposure, scored from
#      the unit text step 4 evaluated, so the hosts are evaluated no third
#      time. Past a cap the run fails, once formatting has run too.
#   7. Formatting, as CI checks it. Last, so a formatting slip never hides an
#      evaluation error or the brief above. Files that were not formatted get
#      formatted, and the run fails so the change is looked at.
#
# The test suites run beside steps 3 and 4: they evaluate nothing and hold
# under 1 GB. Steps 3 and 4 run in turn: on forge they take about 6.5 and 9 GB
# a run, and night-shift agents start several runs at once. Each step's output
# is printed whole when it ends, and the first step to fail ends the run.
#
# --head <rev> checks a commit instead of the working tree, so a branch can be
# briefed without checking it out; formatting is then skipped, since it works
# on files. --json <file> also writes the brief as JSON, for tools that act on
# the verdict.
#
# --flake-check skip leaves out step 3, and --flake-check only runs it alone,
# as CI does on a runner of its own, beside the rest (check.yml).
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

work=$(mktemp -d)
# Each step runs in a process group of its own (set -m), so one kill stops all
# it started, and no nix outlives a run that fails or is stopped: the night
# shift's bwrap and CI's step expect that. INT and TERM exit, for the trap.
declare -A running=() ended=()
cleanup() {
  for pid in "${!running[@]}"; do kill -- "-$pid" 2>/dev/null || true; done
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# start <step> <command...>, its output kept apart so steps never interleave.
start() {
  set -m
  "${@:2}" >"$work/$1.log" 2>&1 &
  set +m
  running[$!]=$1
}
# Until the step named $1 has ended, prints each step as it ends. The first to
# fail ends the run with its status.
await() {
  local pid status
  while [[ -z ${ended[$1]:-} ]]; do
    status=0
    wait -n -p pid "${!running[@]}" || status=$?
    ended[${running[$pid]}]=1
    cat "$work/${running[$pid]}.log" >&$((status == 0 ? 1 : 2))
    ((status == 0)) || exit "$status"
    unset "running[$pid]"
  done
}

# Wall time and peak memory of a nix process, so the log says how close a run
# came to the machine's memory. GNU time, from runtimeInputs.
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
piece() {
  nix eval --impure --json --expr "import $PREFLIGHT_OUTPUTS { ref = \"$ref\"; only = \"$1\"; }" </dev/null >/dev/null \
    2>"$work/piece-$1.err" || { echo "!! flake check: $1 did not evaluate" >>"$work/piece-$1.err" && false; }
}

flake_check() {
  local jobs status=0
  jobs=$(($(nproc) < 8 ? $(nproc) : 8))
  step "flake check: every output but the hosts, $jobs at a time"
  nix eval --impure --json --expr "import $PREFLIGHT_OUTPUTS { ref = \"$ref\"; }" </dev/null >"$work/pieces.json"
  export work ref
  export -f piece
  jq -r '.[]' "$work/pieces.json" | timed flake-check xargs -P "$jobs" -I{} "$BASH" -c "piece {}" || status=$?
  # Each warning once, rather than once a process.
  cat "$work"/piece-*.err | awk '!/warning:/ || !seen[$0]++' >&2
  ((status == 0)) || exit 1
  peak flake-check "flake check, wall time and the largest piece"
}

evaluate() {
  timed "$2" nix eval --impure --json --expr "import $PREFLIGHT_EVAL { ref = \"$1\"; $3 }" \
    </dev/null >"$work/$2.json" 2>"$work/$2.err"
}

# The change failing to evaluate fails the run with nix's error.
eval_head() {
  local status=0
  step "evaluate every host and home config"
  evaluate "$ref" head "withUnits = true;" || status=$?
  cat "$work/head.err"
  ((status == 0)) || exit "$status"
  peak head
}

# The base failing to evaluate is not this change's fault, and says nothing
# about it, so the run goes on. But the comparison is then unknown, not "new",
# and the brief says so rather than flagging every host.
eval_base() {
  step "evaluate them at the base, ${base:0:12}"
  evaluate "git+file://$root?rev=$base" base "" || touch "$work/base.failed"
  peak base
  [[ -e $work/base.failed ]] || return 0
  echo '{"hosts": {}, "homes": {}}' >"$work/base.json"
  echo "!! The base did not evaluate, so what this changes is unknown. Its error ends:"
  tail -n 15 "$work/base.err" | sed 's/^/   /'
}

# Past a cap the run fails, but after formatting, so the step leaves its status.
ratchets() {
  step "ratchets"
  RATCHETS_UNITS=$work/units.json "$BASH" scripts/ratchets.sh ${head:+--rev "$head"} ||
    echo "$?" >"$work/ratchets.status"
}

[[ $flake_check == only ]] || start tests "$BASH" scripts/preflight-tests.sh
if [[ $flake_check != skip ]]; then
  start flake-check flake_check
  await flake-check
fi
[[ $flake_check != only ]] || exit 0

start head eval_head
start base eval_base
await head
jq '.units' "$work/head.json" >"$work/units.json"
start ratchets ratchets
await base
base_ok=true
[[ ! -e $work/base.failed ]] || base_ok=false

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

# The tests' failure ends the run before the brief, as when they ran first.
await tests
echo
brief text
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
  brief md >>"$GITHUB_STEP_SUMMARY"
fi
if [[ -n $json ]]; then
  brief json >"$json"
fi

await ratchets
if [[ -n $head ]]; then
  step "format: skipped, since --head checks a commit and formatting works on files"
else
  step "format"
  nix fmt -- --ci .
fi
[[ ! -s $work/ratchets.status ]] || exit "$(<"$work/ratchets.status")"
