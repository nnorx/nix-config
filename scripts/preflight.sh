# Every check a change needs, in one command, and the one CI runs. Built by
# flake.nix as `apps.<system>.preflight` with writeShellApplication, which adds
# the shebang, errexit, nounset and pipefail. PREFLIGHT_EVAL names
# preflight-eval.nix in the store.
#
#   1. `nix flake check --all-systems --no-build`. --all-systems, or nix skips
#      the aarch64 hosts on an x86 machine; --no-build, so this stays an
#      evaluation and never a multi-hour Pi kernel build.
#   2. Every host's toplevel and every Home Manager config, evaluated. flake
#      check alone does neither: it passes a host whose toplevel cannot
#      evaluate (a missing sops file did exactly that), and it skips
#      homeConfigurations, so a broken WSL or macOS profile looked green.
#   3. Which of them the change actually touches, against a base: by default
#      where this branch left origin/main. That answers whether merging
#      changes the Pis, which upgrade from main the same night.
#   4. Formatting, as CI checks it. Last, so a formatting slip never hides an
#      evaluation error or the table above. Files that were not formatted get
#      formatted, and the run fails so the change is looked at.
#
# Uses the nix on PATH rather than one of its own, so it talks to the daemon in
# the way everything else on the machine does.

usage() {
  echo "usage: preflight [--base <rev>]" >&2
  exit 64
}

base=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --base)
      [[ $# -ge 2 ]] || usage
      base=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

root=$(git rev-parse --show-toplevel)
cd "$root"

step() {
  echo
  echo "==> $*"
}

if [[ -z $base ]]; then
  base=$(git merge-base HEAD origin/main) ||
    {
      echo "preflight: no merge-base with origin/main; fetch it, or pass --base" >&2
      exit 1
    }
  # On main itself, clean and level with origin/main, the comparison would be
  # a commit with itself, and the question worth asking is what the last
  # commit changed. Anywhere else, HEAD as the base is the honest answer: a
  # fresh branch with nothing on it changes nothing.
  if [[ $(git symbolic-ref --quiet --short HEAD || true) == main &&
    $base == "$(git rev-parse HEAD)" ]] && git diff --quiet HEAD; then
    base=$(git rev-parse --verify --quiet 'HEAD^') || base=$(git rev-parse HEAD)
  fi
fi
base=$(git rev-parse --verify "$base^{commit}")

# The flake sees only what git tracks, so a new file that was never added is
# silently absent from every evaluation below.
untracked=$(git ls-files --others --exclude-standard)
if [[ -n $untracked ]]; then
  echo "!! Untracked, so invisible to the flake until \`git add\`:"
  while IFS= read -r path; do echo "   $path"; done <<<"$untracked"
fi

step "flake check"
nix flake check --all-systems --no-build

evaluate() {
  nix eval --impure --json --expr "import $PREFLIGHT_EVAL { ref = \"$1\"; }"
}

step "evaluate every host and home config, and compare with ${base:0:12}"
head_json=$(evaluate "git+file://$root")

# The base failing to evaluate is not this change's fault, and says nothing
# about it, so the run goes on. But the comparison is then unknown, not "new",
# and the table says so rather than flagging every host.
base_ok=true
base_err=$(mktemp)
trap 'rm -f "$base_err"' EXIT
if ! base_json=$(evaluate "git+file://$root?rev=$base" 2>"$base_err"); then
  base_ok=false
  base_json='{"hosts": {}, "homes": {}}'
  echo "!! The base did not evaluate, so what this changes is unknown. Its error ends:"
  tail -n 15 "$base_err" | sed 's/^/   /'
fi

# One line per config in either side: name, kind, state, and for hosts how the
# deployed config, which is the base, gets updated. Tonight's upgrade runs on
# what the host runs now, so a change that turns its upgrade off still
# reaches it once, and a host new in this change has nothing deployed yet.
report=$(jq -rn --argjson head "$head_json" --argjson base "$base_json" --argjson ok "$base_ok" '
  def state($h; $b):
    if $ok | not then "unknown"
    elif $h == null then "removed"
    elif $b == null then "new"
    elif $h == $b then "unchanged"
    else "changed" end;
  (($head.hosts + $base.hosts | keys[]) as $k
    | [$k, "host", state($head.hosts[$k].drv; $base.hosts[$k].drv),
       (if ($ok | not) then "?"
        elif $base.hosts[$k] == null then "-"
        elif $base.hosts[$k].autoUpgrade then "auto"
        else "manual" end)]
    | @tsv),
  (($head.homes + $base.homes | keys[]) as $k
    | [$k, "home", state($head.homes[$k]; $base.homes[$k]), "-"]
    | @tsv)')

auto_changed=$(awk -F'\t' '$2 == "host" && $3 != "unchanged" && $4 == "auto" { printf "%s ", $1 }' <<<"$report")
if ! $base_ok; then
  verdict="The base did not evaluate, so which hosts this reaches tonight is unknown."
elif [[ -n $auto_changed ]]; then
  verdict="Merging changes hosts that upgrade from main tonight: $auto_changed"
else
  verdict="Merging changes no host that upgrades itself."
fi

# Prints the table and the verdict, as plain text or, with `md`, as Markdown.
render() {
  local name kind state deploy
  if [[ $1 == md ]]; then
    echo "### What this changes, against ${base:0:12}"
    echo
    echo "| Config | Kind | State | Deploy |"
    echo "|---|---|---|---|"
  else
    printf '%-14s %-5s %-10s %s\n' NAME KIND STATE DEPLOY
  fi
  while IFS=$'\t' read -r name kind state deploy; do
    if [[ $1 == md ]]; then
      echo "| $name | $kind | $state | $deploy |"
    else
      printf '%-14s %-5s %-10s %s\n' "$name" "$kind" "$state" "$deploy"
    fi
  done <<<"$report"
  echo
  if [[ $1 == md && $verdict != "Merging changes no host"* ]]; then
    echo "**$verdict**"
  else
    echo "$verdict"
  fi
}

echo
render text
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
  render md >>"$GITHUB_STEP_SUMMARY"
fi

step "format"
nix fmt -- --ci .
