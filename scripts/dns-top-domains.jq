# One page of AdGuard Home's query log API (GET /control/querylog) in, one
# tab-separated row per query out: segment, domain, and 1 if it was blocked.
# Run by scripts/dns-top-domains.sh on each page as it arrives, so the client
# address is read here and goes no further.
#
#   $net      lib/net.nix as JSON
#   $full     true to keep whole names rather than their registrable domain
#   $exclude  domain suffixes to report only as "(excluded)"
#
# A query from a segment with `logQueries = false` produces no row at all,
# not even a count. AdGuard should hold none (modules/adguardhome.nix), and
# this keeps the summary right if one gets through.

def ip2int: split(".") | map(tonumber) | .[0] * 16777216 + .[1] * 65536 + .[2] * 256 + .[3];

def segments:
  $net.segments
  | to_entries
  | map({
      name: .key,
      log: (.value.logQueries != false),
      base: (.value.subnet | split("/")[0] | ip2int),
      size: pow(2; 32 - .value.prefixLength)
    });

# The segment's name, "resolvers themselves" for a resolver's own lookups,
# or "no segment".
def segment_of($segs):
  if . == "127.0.0.1" or . == "::1" then { name: "resolvers themselves", log: true }
  elif test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$") then
    ip2int as $n
    | first($segs[] | select($n >= .base and $n < .base + .size)) // { name: "no segment", log: true }
  else { name: "no segment", log: true }
  end;

# Second-level labels under which registries sell third-level names, for
# country-code TLDs: co.uk, com.au, ne.jp. A short list, not the public
# suffix list, so a few names group one level too high.
def sld_labels: ["ac", "co", "com", "edu", "go", "gov", "ne", "net", "or", "org"];

# Names that never leave the house, and reverse lookups, whose names are
# addresses, become a fixed label: a device's hostname or a client address
# would otherwise reach the output through the name asked for.
def domain:
  ascii_downcase
  | rtrimstr(".")
  | split(".") as $l
  | if . == "" then "(root)"
    elif test("\\.in-addr\\.arpa$|\\.ip6\\.arpa$") then "(reverse lookup)"
    elif ($l | length) == 1 then "(local name)"
    elif ($l[-1] | IN("lan", "local", "localdomain", "internal", "home", "corp"))
      or ($l[-2:] == ["home", "arpa"])
    then "(local name)"
    elif any($exclude[]; . as $s | $l | join(".") | . == $s or endswith("." + $s)) then "(excluded)"
    elif $full then $l | join(".")
    elif ($l | length) >= 3 and ($l[-1] | length) == 2 and ($l[-2] | IN(sld_labels[])) then $l[-3:] | join(".")
    else $l[-2:] | join(".")
    end;

segments as $segs
| .data[]
| (.client // "" | segment_of($segs)) as $seg
| select($seg.log)
| [$seg.name, (.question.name // "" | domain), (if (.reason // "") | startswith("Filtered") then 1 else 0 end)]
| @tsv
