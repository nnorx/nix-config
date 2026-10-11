# The domains the house's devices look up most, per segment, from the query
# log on each fleet resolver: the device side of docs/privacy.md, which the
# repo cannot show. Built by flake.nix as `apps.<system>.dns-top-domains` with
# writeShellApplication, which adds the shebang, errexit, nounset and
# pipefail. DNS_TOP_NET is lib/net.nix as JSON and DNS_TOP_ROWS is
# dns-top-domains.jq, both in the store.
#
# Read-only. It asks each resolver's AdGuard Home API for its query log with
# GET requests, as the admin user the web UI uses, and changes nothing. Run it
# from a machine that can reach the AdGuard UI, which is trusted or forge's
# tunnel, in your own terminal: its output is a record of the house's
# browsing, so it does not belong in a transcript.
#
# What the output never holds:
#
#   - Client addresses or names. dns-top-domains.jq reads the address only to
#     find the segment, and keeps the segment's name.
#   - The segments lib/net.nix marks `logQueries = false`, which is work. Not
#     even a count.
#   - Reverse lookups and local names, which spell out an address or a
#     device's hostname. They are counted under a fixed label.
#
# What it can still hold is any domain someone in the house looked up, the
# house's own among them. Read it before pasting it anywhere, and pass
# --exclude for a domain that should not appear by name.
#
# Every row the API returns is held in memory a page at a time and reduced to
# segment, domain and blocked; only the counts reach the temporary file.

usage() {
  cat >&2 <<'EOF'
usage: dns-top-domains [--top N] [--max N] [--full] [--exclude SUFFIX]...

  --top N           domains listed per segment (default 25)
  --max N           stop after about N queries per resolver, 0 for all (default 200000)
  --full            whole names rather than registrable domains
  --exclude SUFFIX  count a domain and its subdomains as "(excluded)"
EOF
  exit 64
}

top=25
max=200000
full=false
exclude=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --top | --max | --exclude)
      [[ $# -ge 2 ]] || usage
      case $1 in
        --top) top=$2 ;;
        --max) max=$2 ;;
        --exclude) exclude+=("$2") ;;
      esac
      shift 2
      ;;
    --full)
      full=true
      shift
      ;;
    *) usage ;;
  esac
done
[[ $top =~ ^[0-9]+$ && $max =~ ^[0-9]+$ ]] || usage

net=$(<"$DNS_TOP_NET")
excludeJson=$(jq -nc '$ARGS.positional' --args -- ${exclude[@]+"${exclude[@]}"})
port=$(jq -r '.ports.adguardWeb' <<<"$net")
mapfile -t resolvers < <(jq -r '.resolvers[]' <<<"$net")

# Bounded by AdGuard: it scans at most 50000 log entries per request.
pageSize=5000

counts=$(mktemp)
trap 'rm -f "$counts"' EXIT

# Each resolver's admin user is named after its host (hosts/<host>). The
# password is read without echo and reaches curl as a config on a descriptor,
# never as an argument. Enter alone reuses the previous resolver's.
password=""
ask() {
  local entered
  if [[ -t 0 ]]; then
    read -rsp "AdGuard password for $1 (user $1, Enter for the previous one): " entered
    echo >&2
  else
    read -r entered || true
  fi
  [[ -z $entered ]] || password=$entered
  [[ -n $password ]] || {
    echo "dns-top-domains: no password for $1" >&2
    exit 1
  }
}

# curl's config syntax: a quoted value with backslash and quote escaped.
credentials() {
  local value="$1:$password"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf 'user = "%s"\n' "$value"
}

# fetch <host>: one row per query, from the newest back, until the log or
# --max runs out. The window it covered goes to stderr.
fetch() {
  local host=$1 ip url page oldest="" previous newest="" last="" read=0 n
  ip=$(jq -r --arg h "$host" '.hosts[$h].ip' <<<"$net")
  url="http://$ip:$port/control/querylog"
  while :; do
    local args=(--get --data "limit=$pageSize")
    [[ -z $oldest ]] || args+=(--data-urlencode "older_than=$oldest")
    page=$(curl -fsS --max-time 120 -K <(credentials "$host") "${args[@]}" "$url") || {
      echo "dns-top-domains: $host did not answer at $url" >&2
      exit 1
    }
    jq -r --argjson net "$net" --argjson full "$full" --argjson exclude "$excludeJson" \
      -f "$DNS_TOP_ROWS" <<<"$page"

    n=$(jq '.data | length' <<<"$page")
    read=$((read + n))
    if [[ $n -gt 0 ]]; then
      [[ -n $newest ]] || newest=$(jq -r '.data[0].time' <<<"$page")
      last=$(jq -r '.data[-1].time' <<<"$page")
    fi

    # `oldest` is empty once the log is exhausted. It is also where the next
    # page starts when AdGuard stopped scanning before filling this one.
    previous=$oldest
    oldest=$(jq -r '.oldest' <<<"$page")
    [[ -n $oldest && $oldest != "$previous" ]] || break
    [[ $max -eq 0 || $read -lt $max ]] || break
  done
  echo "$host: $read queries, ${last:-none} to ${newest:-none}" >&2
}

for host in "${resolvers[@]}"; do
  ask "$host"
  fetch "$host"
done |
  awk -F'\t' -v OFS='\t' '
    { n[$1 FS $2]++; b[$1 FS $2] += $3 }
    END { for (k in n) print k, n[k], b[k] }
  ' >"$counts"

# Segments in VLAN order, then the resolvers' own lookups and anything from
# an address in no segment, as dns-top-domains.jq labels them.
mapfile -t order < <(
  jq -r '.segments | to_entries | map(select(.value.logQueries != false)) | sort_by(.value.id) | .[].key' <<<"$net"
  echo "resolvers themselves"
  echo "no segment"
)
hidden=$(jq -r '[.segments | to_entries[] | select(.value.logQueries == false) | .key] | join(", ")' <<<"$net")

names=registrable
[[ $full == false ]] || names=whole
echo "# Top domains per segment"
echo
echo "From the query logs on ${resolvers[*]}: about the newest $max queries on each (0 is all), as $names domain names."
[[ ${#exclude[@]} -eq 0 ]] || echo "Counted as (excluded): ${exclude[*]}, and their subdomains."
[[ -z $hidden ]] || echo "Left out entirely, by logQueries in lib/net.nix: $hidden."

# Most queried first within each segment, so the first --top rows are the top.
sort -t$'\t' -k1,1 -k3,3nr -k2,2 -o "$counts" "$counts"
for seg in "${order[@]}"; do
  awk -F'\t' -v s="$seg" -v top="$top" '
    $1 != s { next }
    { total += $3; blocked += $4; domains++ }
    domains <= top { row[domains] = sprintf("| %d | %d | %s |", $3, $4, $2) }
    END {
      if (domains == 0) exit
      shown = domains < top ? domains : top
      printf "\n## %s\n\n%d queries, %.1f%% blocked, across %d domains. The top %d:\n\n", s, total, 100 * blocked / total, domains, shown
      print "| Queries | Blocked | Domain |"
      print "|---:|---:|---|"
      for (i = 1; i <= shown; i++) print row[i]
    }
  ' "$counts"
done
