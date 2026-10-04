# Every check a change needs, in one command, and the one CI runs. Built by
# flake.nix as `apps.<system>.preflight` with writeShellApplication, which adds
# the shebang, errexit, nounset and pipefail. PREFLIGHT_EVAL names
# preflight-eval.nix in the store.
#
#   1. Formatting, as CI checks it. Files that were not formatted get
#      formatted, and the run fails so the change is looked at.
#   2. `nix flake check --all-systems --no-build`. --all-systems, or nix skips
#      the aarch64 hosts on an x86 machine; --no-build, so this stays an
#      evaluation and never a multi-hour Pi kernel build.
#   3. Every host's toplevel and every Home Manager config, evaluated. flake
#      check alone does neither: it passes a host whose toplevel cannot
#      evaluate (a missing sops file did exactly that), and it skips
#      homeConfigurations, so a broken WSL or macOS profile looked green.
#   4. Which of them the change actually touches, against a base: by default
#      where this branch left origin/main. That answers whether merging
#      changes the Pis, which upgrade from main the same night.
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
  # On main itself, with nothing uncommitted, the merge-base is HEAD and the
  # comparison would be a commit with itself. The parent is the question worth
  # asking there. With uncommitted changes, HEAD is the right base already.
  if [[ $base == "$(git rev-parse HEAD)" ]] && git diff --quiet HEAD; then
    base=$(git rev-parse HEAD^)
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

step "format"
nix fmt -- --ci .

step "flake check"
nix flake check --all-systems --no-build

evaluate() {
  nix eval --impure --json --expr "import $PREFLIGHT_EVAL { ref = \"$1\"; }"
}

step "evaluate every host and home config, and compare with ${base:0:12}"
head_json=$(evaluate "git+file://$root")

# The base failing to evaluate is not this change's fault, and says nothing
# about it. Everything is then reported as new rather than the run failing.
if ! base_json=$(evaluate "git+file://$root?rev=$base" 2>/dev/null); then
  echo "!! The base did not evaluate; everything below is reported as new."
  base_json='{"hosts": {}, "homes": {}}'
fi

# One line per config: name, kind, changed/unchanged/new, and for hosts
# whether they upgrade themselves.
report=$(jq -rn --argjson head "$head_json" --argjson base "$base_json" '
  def state($h; $b): if $b == null then "new" elif $h == $b then "unchanged" else "changed" end;
  ($head.hosts | to_entries[] | [.key, "host", state(.value.drv; $base.hosts[.key].drv),
     (if .value.autoUpgrade then "auto" else "manual" end)]),
  ($head.homes | to_entries[] | [.key, "home", state(.value; $base.homes[.key]), "-"])
  | @tsv')

echo
printf '%-14s %-5s %-10s %s\n' NAME KIND STATE DEPLOY
while IFS=$'\t' read -r name kind state deploy; do
  printf '%-14s %-5s %-10s %s\n' "$name" "$kind" "$state" "$deploy"
done <<<"$report"

auto_changed=$(awk -F'\t' '$2 == "host" && $3 != "unchanged" && $4 == "auto" { printf "%s ", $1 }' <<<"$report")
echo
if [[ -n $auto_changed ]]; then
  echo "Merging changes hosts that upgrade from main tonight: $auto_changed"
else
  echo "Merging changes no host that upgrades itself."
fi

if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
  {
    echo "### What this changes, against ${base:0:12}"
    echo
    echo "| Config | Kind | State | Deploy |"
    echo "|---|---|---|---|"
    while IFS=$'\t' read -r name kind state deploy; do
      echo "| $name | $kind | $state | $deploy |"
    done <<<"$report"
    echo
    if [[ -n $auto_changed ]]; then
      echo "**Merging changes hosts that upgrade from main tonight:** $auto_changed"
    else
      echo "Merging changes no host that upgrades itself."
    fi
  } >>"$GITHUB_STEP_SUMMARY"
fi
