# exit-bypass <name> [duration] | close <name> | status
#
# Sends a segment in `exitSegments`, or with `exitResolvers` on the
# resolvers' recursion, out `wan` until it is closed or its time runs out.
# Built by ./exit-bypass.nix, which sets the variables above it.
#
# An open bypass is its interface or mark in the set the leak drop skips, an
# `ip rule` to `main` at $priority, the state file gate's metrics read, and a
# transient timer that closes it. Each is made in that order and undone in
# reverse, so no step lets the name out `wan` past the drop or leaves it
# open with no timer. None of them survives a reboot.

usage() {
  echo "usage: exit-bypass <name> [duration] | close <name> | status" >&2
  echo "names: ${!target[*]}. duration: a systemd time span up to 24h, 4h by default" >&2
  exit 64
}

die() {
  echo "exit-bypass: $*" >&2
  exit 1
}

label() {
  if [ "$1" = resolvers ]; then echo "the resolvers' recursion"; else echo "$1"; fi
}

# Out `wan`, as all of gate's own traffic goes. curl reads the URL from
# stdin, so the topic stays out of the process list. A failed push never
# stops an open or a close.
push() {
  printf 'url = "%s"\n' "$(<"$ntfy_url")" |
    curl -fsS --max-time 10 --retry 3 --retry-all-errors -o /dev/null -K - \
      -H "Title: $host: $1" -H "Priority: $2" -H "Tags: $3" -d "$4" ||
    echo "exit-bypass: the push \"$1\" failed" >&2
}

# `iif <interface>` or `fwmark <mark>`: from the state file while open, so a
# bypass still closes after a deploy changes the list.
selector() {
  local kind value
  if [ -e "$state/$1" ]; then
    read -r _ kind value <"$state/$1"
    echo "$kind $value"
  elif [ -n "${target[$1]:-}" ]; then
    echo "${target[$1]}"
  fi
}

# add|delete|get kind value
set_op() {
  local elem=$3
  [ "$2" != iif ] || elem="\"$3\""
  nft "$1" element inet nixos-fw "exit-bypass-$2" "{ $elem }"
}

rule_has() {
  [ -n "$(ip rule show priority "$priority" "$1" "$2" table main)" ]
}

timer() {
  echo "exit-bypass-expire-$1"
}

# Undoes whatever of a bypass is there, rule first.
teardown() {
  local name=$1 kind value
  read -r kind value <<<"$2"
  while ip rule del priority "$priority" "$kind" "$value" table main 2>/dev/null; do :; done
  set_op delete "$kind" "$value" 2>/dev/null || true
  rm -f "$state/$name"
  systemctl stop "$(timer "$name").timer" 2>/dev/null || true
}

open() {
  local name=$1 span=$2 usec expiry kind value
  [ -n "${target[$name]:-}" ] || die "'$name' is not one of: ${!target[*]}"
  [ ! -e "$state/$name" ] || die "$name is already open; exit-bypass close $name first"
  usec=$(systemd-analyze timespan "$span" 2>/dev/null | sed -n '2s/.*: //p')
  # From a second to a day, in μs; the length test keeps `infinity` from overflowing.
  if ! [[ $usec =~ ^[1-9][0-9]{6,10}$ ]] || ((usec > 86400000000)); then
    die "'$span' is not a systemd time span from 1s to 24h, such as 4h or 90min"
  fi
  expiry=$(($(date +%s) + usec / 1000000))
  read -r kind value <<<"${target[$name]}"
  systemctl reset-failed "$(timer "$name").timer" "$(timer "$name").service" 2>/dev/null || true
  [ -d "$state" ] || mkdir -m 0755 "$state"
  if ! {
    set_op add "$kind" "$value" &&
      ip rule add priority "$priority" "$kind" "$value" table main &&
      echo "$expiry $kind $value" >"$state/$name" &&
      systemd-run --quiet --collect --unit="$(timer "$name")" --on-active="$span" \
        --timer-property=AccuracySec=1s -- "$self" close "$name" expired
  }; then
    teardown "$name" "$kind $value"
    die "could not open $name, and left nothing of it open"
  fi
  push "exit bypass open for $name" high warning \
    "$(label "$name") leaves by wan, seen by the ISP, for $span, until $(date -d "@$expiry" '+%a %H:%M'). sudo exit-bypass close $name ends it sooner."
  echo "$name open for $span, until $(date -d "@$expiry" '+%a %H:%M')"
}

close() {
  local name=$1 why=$2 sel
  sel=$(selector "$name")
  [ -n "$sel" ] || die "'$name' is not one of: ${!target[*]}"
  # shellcheck disable=SC2086 # the selector is two words
  if [ ! -e "$state/$name" ] && ! rule_has $sel; then
    echo "$name is not open"
    return 0
  fi
  teardown "$name" "$sel"
  push "exit bypass closed for $name" default lock \
    "$(label "$name") is back in the exit tunnel, failing closed: $why."
  echo "$name closed"
}

# From nftables.service, after every load of the ruleset.
restore() {
  local f name kind value
  for f in "$state"/*; do
    [ -e "$f" ] || continue
    name=${f##*/}
    read -r _ kind value <"$f"
    if set_op add "$kind" "$value" &&
      { rule_has "$kind" "$value" || ip rule add priority "$priority" "$kind" "$value" table main; }; then
      echo "$name kept open across the ruleset's load"
    else
      close "$name" "the firewall's reload could not keep it open"
    fi
  done
}

status() {
  local f names name expiry kind value sel missing now
  now=$(date +%s)
  names=$({
    printf '%s\n' "${!target[@]}"
    for f in "$state"/*; do [ ! -e "$f" ] || echo "${f##*/}"; done
  } | sort -u)
  for name in $names; do
    if [ -e "$state/$name" ]; then
      read -r expiry kind value <"$state/$name"
      missing=""
      rule_has "$kind" "$value" || missing+=" rule"
      set_op get "$kind" "$value" >/dev/null 2>&1 || missing+=" set"
      systemctl is-active --quiet "$(timer "$name").timer" || missing+=" timer"
      printf '%s: open until %s, %d min left' "$name" "$(date -d "@$expiry" '+%a %H:%M')" $(((expiry - now) / 60))
      [ -z "$missing" ] || printf '; missing:%s, so exit-bypass close %s' "$missing" "$name"
      echo
    else
      sel=$(selector "$name")
      # shellcheck disable=SC2086 # the selector is two words
      if rule_has $sel; then
        echo "$name: closed, but its rule to main is still there: exit-bypass close $name"
      else
        echo "$name: closed"
      fi
    fi
  done
}

locked() {
  exec 9>/run/exit-bypass.lock
  flock -w 60 9 || die "another exit-bypass held the lock for a minute"
  "$@"
}

[ "$(id -u)" = 0 ] || die "run it with sudo"
self=$(readlink -f "$0")

case ${1:-} in
  "" | -h | --help) usage ;;
  status)
    [ $# = 1 ] || usage
    status
    ;;
  close)
    [[ $# = 2 || ($# = 3 && $3 = expired) ]] || usage
    if [ $# = 3 ]; then why="its time ran out"; else why="closed by hand"; fi
    locked close "$2" "$why"
    ;;
  restore) locked restore ;;
  *)
    [ $# -le 2 ] || usage
    locked open "$1" "${2:-4h}"
    ;;
esac
