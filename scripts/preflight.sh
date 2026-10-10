# Every check a change needs, in one command, and the one CI runs. Built by
# flake.nix as `apps.<system>.preflight` with writeShellApplication, which adds
# the shebang, errexit, nounset and pipefail. PREFLIGHT_EVAL and
# PREFLIGHT_BRIEF name preflight-eval.nix and preflight-brief.jq in the store.
#
#   1. The brief's rules, against the hand-written cases in
#      tests/preflight-brief/ (scripts/test-preflight-brief.sh). A slip in a
#      rule changes verdicts with no error, so this fails the run instead.
#      First, since it takes milliseconds.
#   2. `nix flake check --all-systems --no-build`. --all-systems, or nix skips
#      the aarch64 hosts on an x86 machine; --no-build, so this stays an
#      evaluation and never a multi-hour Pi kernel build.
#   3. Every host's toplevel and every Home Manager config, evaluated. flake
#      check alone does neither: it passes a host whose toplevel cannot
#      evaluate (a missing sops file did exactly that), and it skips
#      homeConfigurations, so a broken WSL or macOS profile looked green.
#   4. The brief: which of them the change actually touches, against a base,
#      by default where this branch left origin/main, and for each host what
#      kind of change it gets (scripts/preflight-brief.jq). That answers
#      whether merging changes the Pis, which upgrade from main the same
#      night, and whether that needs Nick at hand. It is advice and never
#      fails the run.
#   5. Formatting, as CI checks it. Last, so a formatting slip never hides an
#      evaluation error or the brief above. Files that were not formatted get
#      formatted, and the run fails so the change is looked at.
#
# --head <rev> checks a commit instead of the working tree, so a branch can be
# briefed without checking it out; formatting is then skipped, since it works
# on files. --json <file> also writes the brief as JSON, for tools that act on
# the verdict.
#
# Uses the nix on PATH rather than one of its own, so it talks to the daemon in
# the way everything else on the machine does.

usage() {
  echo "usage: preflight [--base <rev>] [--head <rev>] [--json <file>]" >&2
  exit 64
}

base=""
head=""
json=""
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || usage
  case $1 in
    --base) base=$2 ;;
    --head) head=$2 ;;
    --json) json=$2 ;;
    *) usage ;;
  esac
  shift 2
done
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

if [[ -z $base ]]; then
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
base=$(git rev-parse --verify "$base^{commit}")

# The flake sees only what git tracks, so a new file that was never added is
# silently absent from every evaluation below.
untracked=$(git ls-files --others --exclude-standard)
if [[ -z $head && -n $untracked ]]; then
  echo "!! Untracked, so invisible to the flake until \`git add\`:"
  while IFS= read -r path; do echo "   $path"; done <<<"$untracked"
fi

step "brief rules"
# Under --head too: the brief below uses the rules this preflight was built
# with (PREFLIGHT_BRIEF), not the commit's, and those are what this tests.
# $BASH, since writeShellApplication puts no bash on PATH.
"$BASH" scripts/test-preflight-brief.sh

step "flake check"
nix flake check --all-systems --no-build "$ref"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

evaluate() {
  nix eval --impure --json --expr "import $PREFLIGHT_EVAL { ref = \"$1\"; }"
}

step "evaluate every host and home config, and compare with ${base:0:12}"
evaluate "$ref" >"$work/head.json"

# The base failing to evaluate is not this change's fault, and says nothing
# about it, so the run goes on. But the comparison is then unknown, not "new",
# and the brief says so rather than flagging every host.
base_ok=true
if ! evaluate "git+file://$root?rev=$base" >"$work/base.json" 2>"$work/base.err"; then
  base_ok=false
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
