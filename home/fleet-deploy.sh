# fleet-deploy: main, onto the Pis, by day, one host at a time, through each
# Pi's deploy login (modules/deploy-agent.nix). Built by home/fleet-deploy.nix
# with writeShellApplication, which adds the shebang, errexit, nounset and
# pipefail. FLEET_DEPLOY_KEY names the deploy key.
#
#   fleet-deploy [host...]                   deploy main, by default to every Pi
#   fleet-deploy status|hold|release [host...]
#
# Run it from a nix-config checkout: the brief is preflight's, run in a
# temporary worktree of it at main. status, hold and release read which hosts
# are Pis from the checkout as it is, and touch neither GitHub nor main, so a
# hold still works while either is broken.
#
# For each host, in the order they upgrade at night, so lifeline goes first and
# is the canary for the rest:
#
#   1. Its deploy login's `status`. A held host, or one already on main, is
#      left alone.
#   2. preflight's brief, against the revision the host runs: what deploying
#      main changes there. A host whose brief says `be there`, or whose
#      revision cannot be briefed, needs its name typed; any other host a y.
#      A host with main already staged for its next boot gets the same brief
#      and question, for the reboot that boots it.
#   3. Its system in the cache. The upgrade substitutes or fails, so started
#      before cache.yml has pushed main it fails, harmlessly. While cache.yml
#      runs for main this waits for it.
#   4. `upgrade`, which starts the nightly unit and returns with its status.
#      Outside the reboot window a new kernel is staged rather than switched,
#      and then the reboot is offered. Inside it the upgrade schedules its own
#      reboot. Either way the host is seen to go down and come back.
#
# The first host that does not end on main, running and with no newly failed
# units, stops the run, so a bad main reaches one resolver, not both. A host
# skipped at its prompt does not.
#
# Ctrl-C stops this, never a host: an upgrade or reboot already asked for
# belongs to systemd on the Pi and finishes, and `status` shows how.
#
# gate is not here. It has no upgrade unit and no deploy login, and is
# deployed by hand.

usage() {
  echo "usage: fleet-deploy [host...] | fleet-deploy status|hold|release [host...]" >&2
  exit 64
}

repo=https://github.com/nnorx/nix-config
cache=https://nnorx-nix-config.cachix.org
key=$FLEET_DEPLOY_KEY

verb=deploy
case ${1:-} in
  status | hold | release)
    verb=$1
    shift
    ;;
  -*) usage ;;
esac

root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "fleet-deploy: run it from a nix-config checkout" >&2
  exit 64
}
case $(git -C "$root" remote get-url origin 2>/dev/null) in
  *nnorx/nix-config*) ;;
  *)
    echo "fleet-deploy: $root is not a nix-config checkout" >&2
    exit 64
    ;;
esac

tmp=$(mktemp -d)
cleanup() {
  if [[ -d $tmp/main ]]; then
    git -C "$root" worktree remove --force "$tmp/main" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die() {
  printf 'fleet-deploy: %s\n' "$*" >&2
  exit 1
}

# Every host in a flake that upgrades itself, with the facts named, each a Nix
# binding over the host's config `c`.
hosts_of() {
  nix eval --json --accept-flake-config "$1#nixosConfigurations" --apply "
    cs: builtins.mapAttrs (_: c: { $2 }) (builtins.removeAttrs cs
      (builtins.filter (n: !cs.\${n}.config.system.autoUpgrade.enable) (builtins.attrNames cs)))
  " >"$tmp/hosts.json" 2>"$tmp/eval.err" || {
    cat "$tmp/eval.err" >&2
    die "could not evaluate $1"
  }
}

if [[ $verb == deploy ]]; then
  # What GitHub calls main, which is what the hosts' upgrade fetches.
  git -C "$root" fetch --quiet origin main || die "could not fetch main"
  main=$(git -C "$root" rev-parse FETCH_HEAD)

  # Read from main itself, so a Pi added or retimed there is deployed as main
  # has it, and evaluated from GitHub at that commit, which is what the hosts
  # fetch, so each toplevel is the path their upgrade asks the cache for. The
  # reboot window is compared with the clock in the host's own time zone, as
  # the upgrade does.
  hosts_of "github:nnorx/nix-config/$main" '
    at = c.config.system.autoUpgrade.dates;
    toplevel = c.config.system.build.toplevel.outPath;
    window = c.config.system.autoUpgrade.rebootWindow;
    tz = c.config.time.timeZone;'
else
  hosts_of "git+file://$root" 'at = c.config.system.autoUpgrade.dates;'
fi
mapfile -t pis < <(jq -r 'to_entries | sort_by(.value.at) | .[].key' "$tmp/hosts.json")

if [[ $# -eq 0 ]]; then
  hosts=("${pis[@]}")
else
  for asked in "$@"; do
    [[ " ${pis[*]} " == *" $asked "* ]] ||
      die "$asked has no deploy login; only the Pis do (${pis[*]}). gate is deployed by hand."
  done
  hosts=()
  for host in "${pis[@]}"; do
    if [[ " $* " == *" $host "* ]]; then
      hosts+=("$host")
    fi
  done
fi

# The deploy key, loaded once here, so the logins below never stop to ask for
# its passphrase. BatchMode then turns anything else that would prompt into a
# refusal rather than a hang.
if ! ssh-add -T "$key.pub" 2>/dev/null; then
  say "Loading the deploy key, which every login below uses:"
  ssh-add "$key" || die "the deploy key is not loaded"
fi

# agent <seconds> <host> <verb>: one request to a host's deploy login, given
# up after that long. ConnectTimeout covers only connecting, and the
# keepalives only a link that drops, so `timeout` covers a host that takes
# the session and then hangs, as one with a failing root device does. -n,
# since ssh otherwise reads this script's stdin, the answers to its prompts.
agent() {
  timeout "$1" ssh -n -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -- "deploy@$2" "$3"
}

# One fact from a status, by key.
get() { awk -F '\t' -v k="$1" '$1 == k { print $2 }' <<<"$2"; }

indent() { sed 's/^/   /'; }

if [[ $verb != deploy ]]; then
  failed=0
  for host in "${hosts[@]}"; do
    step "$host $verb"
    # The agent's own deadline for hold and release is 2 minutes.
    agent 150 "$host" "$verb" 2>&1 | indent || failed=1
  done
  exit "$failed"
fi

# --- The brief ---------------------------------------------------------------

# preflight's JSON brief for main against a revision, made once per revision,
# since the Pis usually all run the same one. Run in a worktree at main, so
# the brief's rules and its own tests are main's, whatever the checkout has
# out. Its output is shown as it runs, on stderr, since stdout is the path;
# the brief is at the end. A failed run leaves no file, so the next host on
# that revision runs it again rather than reading half a brief.
brief() {
  local rev=$1 json=$tmp/brief-$1.json
  if [[ ! -s $json ]]; then
    if [[ ! -d $tmp/main ]]; then
      git -C "$root" worktree add --quiet --detach "$tmp/main" "$main" >&2
    fi
    step "brief: what main changes against ${rev:0:12} (a few minutes)" >&2
    if ! (cd "$tmp/main" && nix run .#preflight -- --base "$rev" --head "$main" \
      --flake-check skip --json "$json") >&2 || [[ ! -s $json ]]; then
      rm -f "$json"
      return 1
    fi
  fi
  printf '%s\n' "$json"
}

# The brief's word on deploying main to a host: be there, review or routine,
# or unchanged when main changes nothing there but the revision. A brief that
# cannot be read is be there.
level() {
  local lvl
  lvl=$(jq -r --arg h "$1" '
    if .verdict.level == "unknown" then "be there"
    elif (first(.configs[] | select(.name == $h) | .state) // "") == "unchanged" then "unchanged"
    else [(.hosts[$h].findings // [])[], .plan[] | .level]
      | if any(. == "be there") then "be there"
        elif any(. == "review") then "review"
        else "routine" end
    end' "$2" 2>/dev/null) || lvl=""
  printf '%s\n' "${lvl:-be there}"
}

# Briefs main for a host and asks the question, wanting the host's name typed
# where the brief says `be there` or there is no brief.
go_ahead() {
  local host=$1 rev=$2 question=$3 json lvl word=$1
  # A revision that is not a commit on main, a dirty tree's or a branch's
  # tried with `nixos-rebuild test`, has nothing to brief against.
  if [[ $rev =~ ^[0-9a-f]{40}$ ]] && git -C "$root" merge-base --is-ancestor "$rev" "$main" 2>/dev/null; then
    if json=$(brief "$rev"); then
      lvl=$(level "$host" "$json")
      say "   the brief for $host: $lvl"
      [[ $lvl == "be there" ]] || word=""
    else
      say "!! preflight failed above, so what main changes on $host is unknown."
    fi
  else
    say "!! $host runs ${rev:0:12}, which is not a commit on main, so there is no brief for it."
  fi
  confirm "$question" "$word"
}

# --- The cache ---------------------------------------------------------------

# 0 when the cache has a store path, 1 when it does not, 2 when it did not say.
cached() {
  local code
  code=$(curl -sS -o /dev/null --max-time 15 -w '%{http_code}' \
    "$cache/$(basename "$1" | cut -c1-32).narinfo" 2>/dev/null) || code=000
  case $code in
    200) return 0 ;;
    404) return 1 ;;
    *) return 2 ;;
  esac
}

# cache.yml's run for main: its status and conclusion, `none` when GitHub
# lists no run, or `unknown` when it did not answer, which includes its rate
# limit: 60 calls an hour without a token, shared with everything else on
# this address. So it is asked every other minute, and the cache every 30
# seconds.
cache_run() {
  local body
  body=$(curl -sS --max-time 15 \
    "https://api.github.com/repos/nnorx/nix-config/actions/workflows/cache.yml/runs?head_sha=$main&per_page=1" 2>/dev/null) || {
    echo unknown
    return
  }
  jq -r '
    if (.workflow_runs | type) != "array" then "unknown"
    elif .workflow_runs == [] then "none"
    else .workflow_runs[0] | "\(.status) \(.conclusion // "-")" end' <<<"$body" 2>/dev/null || echo unknown
}

wait_for_cache() {
  local host=$1 path=$2 polls=0 run="" status=0
  while true; do
    status=0
    cached "$path" || status=$?
    ((status == 0)) && return 0
    if ((polls % 4 == 0)); then
      run=$(cache_run)
      case $run in
        completed*)
          # Pushed between the two questions, or not at all.
          cached "$path" && return 0
          die "cache.yml finished for main (${run#* }) but $host's system is not in the cache: $repo/actions/workflows/cache.yml"
          ;;
        none)
          # A push takes a moment to show up as a run.
          ((polls < 10)) || die "no cache.yml run for main after 5 minutes: $repo/actions/workflows/cache.yml"
          ;;
      esac
      case $run in
        unknown) say "   $host's system is not in the cache yet, and GitHub did not say how cache.yml is doing; asking again" ;;
        *) say "   $host's system is not in the cache yet; cache.yml is ${run%% *}, $((polls / 2)) min so far (Ctrl-C stops only this)" ;;
      esac
    fi
    ((status == 2)) && say "   the cache did not answer; asking again"
    polls=$((polls + 1))
    sleep 30
  done
}

# --- A host ------------------------------------------------------------------

# A question answered y, or with a word typed back when one is given: the
# host's name, for the brief's `be there`.
confirm() {
  local question=$1 word=${2:-} answer=""
  if [[ -n $word ]]; then
    read -r -p "$question Type $word to go ahead, anything else skips it: " answer || true
    [[ $answer == "$word" ]]
  else
    read -r -p "$question [y/N] " answer || true
    [[ $answer == y || $answer == Y ]]
  fi
}

# Inside the host's reboot window, where the upgrade reboots for a new kernel
# by itself, a minute after it ends. The same comparison as nixpkgs'
# auto-upgrade, on the host's clock.
in_window() {
  local now lower upper
  lower=$(jq -r --arg h "$1" '.[$h].window.lower // empty' "$tmp/hosts.json")
  upper=$(jq -r --arg h "$1" '.[$h].window.upper // empty' "$tmp/hosts.json")
  [[ -n $lower && -n $upper ]] || return 1
  now=$(TZ=$(jq -r --arg h "$1" '.[$h].tz // "UTC"' "$tmp/hosts.json") date +%H:%M)
  if [[ $lower < $upper ]]; then
    [[ $now > $lower && $now < $upper ]]
  else
    [[ $now < $upper || $now > $lower ]]
  fi
}

# Waits for a host to go down and answer again, and prints its status. Seeing
# it go down is what says the reboot happened: the old system can answer for
# a while after the reboot is asked for, while it stops its services, and a
# request that never reached the host looks to ssh like one cut off by the
# reboot.
rebooted() {
  local host=$1 out polls=0
  # Counted in polls, about 3 and 10 minutes, rather than by the clock, so
  # the tests' stand-in sleep, which returns at once, can run them out.
  while agent 15 "$host" status >/dev/null 2>&1; do
    ((++polls < 36)) || die "$host still answers 3 minutes after its reboot was due, so it did not reboot; check on it"
    sleep 5
  done
  say "   $host is down; waiting for it to come back (up to 10 minutes)" >&2
  polls=0
  until out=$(agent 30 "$host" status 2>/dev/null); do
    ((++polls < 60)) || die "$host has not answered for 10 minutes since it went down; check on it"
    sleep 10
  done
  printf '%s\n' "$out"
}

# A host is done when it runs main with no unit failed that had not already
# failed before the deploy. Prints why not.
settled() {
  local host=$1 status=$2 before=$3 rev unit new=() old=()
  rev=$(get revision "$status")
  if [[ $rev != "$main" ]]; then
    say "!! $host runs ${rev:0:12}, not main (${main:0:12}). If main moved during the deploy, the brief above was not for it."
    return 1
  fi
  for unit in $(get failed "$status"); do
    [[ $unit == none ]] && continue
    if [[ " $before " == *" $unit "* ]]; then old+=("$unit"); else new+=("$unit"); fi
  done
  if ((${#old[@]} > 0)); then
    say "   still failed, as before the deploy: ${old[*]}"
  fi
  if ((${#new[@]} > 0)); then
    say "!! $host has units that failed during the deploy: ${new[*]}"
    return 1
  fi
}

# Reboots a host into its staged system and checks the boot.
reboot_into_main() {
  local host=$1 before=$2 status code=0
  agent 150 "$host" reboot 2>&1 | indent || code=${PIPESTATUS[0]}
  case $code in
    # 255 is ssh's own: the reboot can close the session before the agent's
    # answer is sent, and so can a request that never got there. rebooted
    # tells them apart.
    0 | 255) ;;
    75) die "$host refused to reboot while something ran that it would cut off; run fleet-deploy again when it ends" ;;
    *) die "$host did not reboot" ;;
  esac
  status=$(rebooted "$host")
  printf '%s\n' "$status" | indent
  settled "$host" "$status" "$before" || exit 1
}

deploy() {
  local host=$1 status rev before code=0
  step "$host"
  status=$(agent 60 "$host" status) || die "$host did not answer its deploy login"
  printf '%s\n' "$status" | indent
  rev=$(get revision "$status")
  before=$(get failed "$status")

  if [[ $(get hold "$status") == yes ]]; then
    say "   held, so left alone. 'fleet-deploy release $host' lets it upgrade again."
    return 0
  fi
  if [[ $(get staged "$status") == yes && $(get next-boot "$status") == "$main" ]]; then
    say "   main is staged for $host's next boot: a new kernel, initrd or modules."
    if go_ahead "$host" "$rev" "Reboot $host into main now?"; then
      reboot_into_main "$host" "$before"
    else
      say "   left staged; tonight's upgrade reboots it inside the window."
    fi
    return 0
  fi
  if [[ $rev == "$main" ]]; then
    say "   already on main."
    return 0
  fi

  go_ahead "$host" "$rev" "Deploy main to $host?" || {
    say "   skipped."
    return 0
  }

  wait_for_cache "$host" "$(jq -r --arg h "$host" '.[$h].toplevel' "$tmp/hosts.json")"

  say "   upgrading; a substitute-only run takes minutes"
  # The agent gives up on the upgrade after an hour.
  status=$(agent 3700 "$host" upgrade 2>"$tmp/upgrade.err") || code=$?
  case $code in
    0) printf '%s\n' "$status" | indent ;;
    69) die "$host was held while this ran" ;;
    75)
      indent <"$tmp/upgrade.err"
      die "$host was busy; run fleet-deploy again when its run ends"
      ;;
    *)
      indent <"$tmp/upgrade.err"
      die "the upgrade on $host failed"
      ;;
  esac

  if [[ $(get staged "$status") != yes ]]; then
    settled "$host" "$status" "$before" || exit 1
    return 0
  fi
  rev=$(get next-boot "$status")
  if [[ $rev != "$main" ]]; then
    say "!! $host staged ${rev:0:12}, not main (${main:0:12}). If main moved during the deploy, the brief above was not for it."
    exit 1
  fi
  say "   main is staged for $host's next boot: a new kernel, initrd or modules."
  if in_window "$host"; then
    # Asking for a second reboot would race the one already scheduled.
    say "   inside the reboot window, so the upgrade has scheduled its own reboot a minute out"
    status=$(rebooted "$host")
    printf '%s\n' "$status" | indent
    settled "$host" "$status" "$before" || exit 1
  elif confirm "Reboot $host into main now?"; then
    reboot_into_main "$host" "$before"
  else
    say "   left staged; tonight's upgrade reboots it inside the window."
  fi
}

say "main is ${main:0:12}; deploying it to ${hosts[*]}, one at a time"
for host in "${hosts[@]}"; do
  deploy "$host"
done
step "done"
