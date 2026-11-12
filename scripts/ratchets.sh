# Numbers that may only go down, each capped in scripts/ratchets.json. Past a
# cap the run fails. preflight runs this.
#
#   prose     words in every markdown file outside tests/
#   comments  comment lines as a share of non-blank lines, per language
#   shell     lines in any one shell script: `default`, or the script's own cap
#             under `allow` while it is cut down or ported
#   systemd   the exposure `systemd-analyze security` gives "<host>/<unit>",
#             for each unit that listens (scripts/systemd-security.nix)
#
# --tighten lowers each cap to the tree's measure, and drops a script's own cap
# once it fits the default. --rev <rev> measures a commit, not the working tree.
# RATCHETS_CAPS and RATCHETS_STAND_INS are scripts/test-ratchets-systemd.sh's.

usage() {
  echo "usage: ratchets.sh [--rev <rev> | --tighten]" >&2
  exit 64
}

rev=""
tighten=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --rev)
      [[ $# -ge 2 ]] || usage
      rev=$2
      shift
      ;;
    --tighten) tighten=true ;;
    *) usage ;;
  esac
  shift
done
[[ -z $rev ]] || ! $tighten || usage

cd "$(git rev-parse --show-toplevel)"
caps=${RATCHETS_CAPS:-scripts/ratchets.json}

# Untracked files count, so a new doc is measured before it is added.
files() {
  if [[ -n $rev ]]; then
    git ls-tree -r --name-only "$rev"
  else
    git ls-files --cached --others --exclude-standard |
      while IFS= read -r f; do if [[ -f $f ]]; then printf '%s\n' "$f"; fi; done
  fi
}
content() {
  if [[ -n $rev ]]; then git show "$rev:$1"; else cat -- "$1"; fi
}

if ! content "$caps" >/dev/null 2>&1; then
  echo "ratchets: no $caps in ${rev:-the working tree}, so nothing to check"
  exit 0
fi

prose=0
declare -A comment=() code=()
shell=""
while IFS= read -r f; do
  if [[ $f == *.md && $f != tests/* ]]; then
    prose=$((prose + $(content "$f" | wc -w)))
  fi
  lang=""
  case $f in
    *.nix) lang=nix ;;
    *.sh) lang=sh ;;
    *) content "$f" 2>/dev/null | head -n 1 | grep -qE '^#!.*\b(ba)?sh\b' && lang=sh ;;
  esac
  [[ -n $lang ]] || continue
  read -r c k < <(content "$f" | awk 'NR == 1 && /^#!/ { next } /^[[:space:]]*#/ { c++; next } /[^[:space:]]/ { k++ } END { print c + 0, k + 0 }')
  comment[$lang]=$((${comment[$lang]:-0} + c))
  code[$lang]=$((${code[$lang]:-0} + k))
  if [[ $lang == sh ]]; then shell+="$f"$'\t'"$(content "$f" | wc -l)"$'\n'; fi
done < <(files)

measured=$(
  for lang in "${!comment[@]}"; do
    awk -v l="$lang" -v c="${comment[$lang]}" -v k="${code[$lang]}" 'BEGIN { printf "%s\t%.1f\n", l, 100 * c / (c + k) }'
  done | jq -Rn --argjson prose "$prose" --arg shell "$shell" '
    {prose: $prose,
     comments: [inputs | split("\t") | {key: .[0], value: (.[1] | tonumber)}] | from_entries,
     shell: [$shell | split("\n")[] | select(. != "") | split("\t") | {key: .[0], value: (.[1] | tonumber)}] | from_entries}'
)

# Scored in a build, since systemd-analyze writes to /tmp and /run, which the
# sandbox keeps read-only. Off Linux there is no systemd to score with.
units=$(content "$caps" | jq -c '.systemd // {} | keys')
scores='{}'
if [[ $units != '[]' && $(uname -s) != Linux ]]; then
  echo "ratchets: systemd exposure needs Linux, so it is not measured here"
elif [[ $units != '[]' ]]; then
  ref=git+file://$PWD
  if [[ -n $rev ]]; then ref+="?rev=$(git rev-parse --verify "$rev^{commit}")"; fi
  stand_ins=${RATCHETS_STAND_INS:+standIns = \"$RATCHETS_STAND_INS\";}
  out=$(nix build --impure --no-link --print-out-paths --expr \
    "import $PWD/scripts/systemd-security.nix { ref = \"$ref\"; units = builtins.fromJSON ''$units''; $stand_ins }") ||
    exit
  scores=$(cat "$out")
fi
measured=$(jq --argjson s "$scores" '.systemd = $s' <<<"$measured")

if $tighten; then
  jq --argjson m "$measured" '
    .prose = ([.prose, $m.prose] | min)
    | .comments |= with_entries(.value = ([.value, $m.comments[.key] // .value] | min))
    | .shell.default as $d
    | .shell.allow |= with_entries(($m.shell[.key] // 0) as $n | select($n > $d) | .value = ([.value, $n] | min))
    | if .systemd then .systemd |= with_entries(.value = ([.value, $m.systemd[.key] // .value] | min)) else . end
  ' "$caps" >"$caps.next"
  mv "$caps.next" "$caps"
  echo "ratchets: caps lowered to the tree's measure, where it was below"
fi

content "$caps" | jq -r --argjson m "$measured" '
  . as $c
  | def over: if .now > .cap then "!! over:  " elif .now < .cap then "   below: " else "   at:    " end;
    ([{name: "prose (words)", now: $m.prose, cap: $c.prose}]
     + [$m.comments | to_entries[] | {name: "comments in .\(.key) (%)", now: .value, cap: ($c.comments[.key] // 0)}]
     + [$m.shell | to_entries[] | ($c.shell.allow[.key] // $c.shell.default) as $cap
        | select(.value > $c.shell.default or $c.shell.allow[.key] != null)
        | {name: "\(.key) (lines)", now: .value, cap: $cap}]
     + [$c.shell.allow | keys[] | select($m.shell[.] == null) | {name: "\(.) (gone)", now: 0, cap: $c.shell.allow[.]}]
     + [$c.systemd // {} | to_entries[] | select($m.systemd[.key] != null) | {name: "\(.key) (exposure)", now: $m.systemd[.key], cap: .value}])
  | map("\(over)\(.name): \(.now), cap \(.cap)")[]'

if content "$caps" | jq -e --argjson m "$measured" '
  . as $c
  | $m.prose > $c.prose
    or any($m.comments | to_entries[]; .value > ($c.comments[.key] // 0))
    or any($m.shell | to_entries[]; .value > ($c.shell.allow[.key] // $c.shell.default))
    or any($m.systemd | to_entries[]; .value > $c.systemd[.key])
' >/dev/null; then
  echo "ratchets: over a cap. Cut the change back; raising a cap is Nick's call, made in the PR body." >&2
  exit 1
fi
if ! $tighten && content "$caps" | jq -e --argjson m "$measured" '
  . as $c
  | $m.prose < $c.prose
    or any($m.comments | to_entries[]; .value < ($c.comments[.key] // 0))
    or any($c.shell.allow | to_entries[]; .value > ($m.shell[.key] // 0))
    or any($m.systemd | to_entries[]; .value < $c.systemd[.key])
' >/dev/null; then
  echo "ratchets: below a cap. Run scripts/ratchets.sh --tighten and commit the lower caps."
fi
