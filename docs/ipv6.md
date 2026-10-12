# IPv6 on gate

A plan, from NNO-31, for the IPv6 item in Phase 8 of [router.md](router.md).
Nothing in it is deployed. It says where gate stands today, how to find out
what the ISP offers without risking the house's only router, the design, and
[the PRs in order](#the-prs-in-order), each small enough to review and to
undo.

The gate metrics this rollout is watched through landed in #157
([observability.md](observability.md), step 2), so nothing here waits on them.

## Where it stands

Read from gate's configuration on 2026-10-11, and checked on gate itself on
2026-10-12, as noted below.

- **The kernel has IPv6, and dhcpcd listens for it on `wan`.**
  `networking.enableIPv6` is at its default, and dhcpcd runs on `wan` with
  its own defaults: it solicits router advertisements (RAs), and would take a
  SLAAC address or a DHCPv6 one if an RA offered either. It has never asked
  for a prefix: gate's generated `dhcpcd.conf` has no `ia_pd`. So "off on
  `wan`" is not quite it. gate listens, and has never asked.
- **gate forwards no IPv6.** `networking.nat.enableIPv6` is false, so
  `net.ipv6.conf.all.forwarding` stays 0. It sends no RAs on any segment and
  runs no DHCPv6 server, so no client in the house has a global address.
- **2026-10-01: no global IPv6 on `wan`.** With dhcpcd configured as above,
  that means the ISP sent no RA at all, or one with neither a prefix for
  SLAAC nor the managed flag, which would have had dhcpcd ask for an address.
  It says nothing about delegation, which only a request answers. Still so
  on 2026-10-12: `wan` holds a link-local address only, and gate has no IPv6
  default route. The kernel's `accept_ra` on `wan` is 0, as it should be,
  since dhcpcd handles RAs there itself.
- **gate takes RAs from its own LAN.** Every interface except `wan` has the
  kernel's host defaults, `accept_ra = 1` and `autoconf = 1`, and the
  firewall accepts ICMPv6 on input. So a device on any segment that sends an
  RA gives gate addresses in its prefix and, if the RA says it is a default
  router, a default route through that device. Thread border routers, the
  kind of device iot holds, advertise prefixes as a matter of course, usually
  without claiming the default route. A device that did claim it would draw
  gate's
  own IPv6 traffic, to anything dual-stacked such as the binary caches,
  through itself. Low severity today, and cheap to close; it is the first
  gate PR below. Checked on 2026-10-12: `lan0`, `lan0.30` and `br-trusted`
  all have `accept_ra = 1` and `autoconf = 1`, and no interface on gate holds
  a global IPv6 address, so nothing on the LAN is advertising one yet.

The useful property for everything that follows: **gate's forward policy is
written in interface names, so most of it already holds for IPv6.**
`networking.nat` accepts `iifname { every segment } oifname "wan"` with no
address family, and every inter-segment rule in `hosts/gate/routing.nix` is
`iifname`/`oifname`. Both families get the same answer from those. What is
IPv4 only is the rules that name an address:

| Rule | Where | IPv6 today |
|---|---|---|
| Upstream management deny, `ip daddr { private ranges }` | `hosts/gate/routing.nix` | No twin. Needs `fc00::/7` |
| DNS redirect | `ip nixos-nat` table, `hosts/gate/routing.nix` | IPv4 only, by table family |
| Refuse DoT and DoQ | `hosts/gate/routing.nix` | **Already covers IPv6**: the rules match no family |
| Govee's LAN API | `hosts/gate/govee.nix` | IPv4 only, and stays so: iot gets no prefix below |
| WireGuard grants and the "no exit" drop | `hosts/gate/wireguard.nix` | IPv4 only, and complete while peers have no IPv6 address (below) |
| Reverse-path filter | nixpkgs' `rpfilter` chain | Covers both: the table is `inet`, strict mode |
| Inbound from `wan` | nixpkgs' `forward-allow` | Default drop, **except ICMPv6**, which nixpkgs accepts ahead of every rule here, echo requests included |

The last row is why the inbound deny has to be written down rather than
inherited, below.

## What it buys, and what it costs

gate holds a public IPv4 address, so the usual reason for IPv6 at home,
getting out from behind CGNAT, does not apply. What it buys is direct paths
to services that prefer IPv6, connections that need no NAT traversal (calls,
games), and a house that keeps working if the ISP moves to IPv6-first.

What it costs is a second address family in every rule that names an
address, and **global addressability for every device given a prefix**,
with gate's forward chain as the only thing in front of it. Older devices
that form their address from their MAC (EUI-64) also show that MAC to every
server they talk to; current phones and laptops use privacy addresses
instead.

That balance is why the plan gives IPv6 to trusted, then guest, then work if
wanted, and to nothing else.

## Finding out what the ISP offers

Two rungs, the first changing nothing.

### Read what gate already hears

`dhcpcd` on `wan` already acts on any RA, so whether the ISP runs IPv6 on
this line at all is visible now, read-only. From an admin machine at home:

```
fleet-ssh gate 'ip -6 route show default dev wan | wc -l; ip -6 -o addr show dev wan scope global | wc -l'
```

The first number is 1 if the ISP sends RAs naming itself the default router,
the second counts global addresses on `wan`. Both print counts, never
addresses. The metrics PR below makes the same two numbers permanent, so the
answer is on a graph before the probe runs. A 0 on the first does not rule
delegation out: some ISPs answer DHCPv6 without advertising. On
2026-10-12 both were 0, so the probe below is what decides it.

### The probe: ask once, with a reboot as the undo

A branch, `ipv6-probe`, never merged, that adds two lines to the
`interface wan` block `hosts/gate/default.nix` already has, which keeps
gate's hostname and vendor class out of its requests (F12, #171):

```nix
networking.dhcpcd.extraConfig = ''
  interface wan
  hostname ""
  vendorclassid
  ia_na 1
  ia_pd 2/::/56 -
'';
```

- `ia_na 1` asks for an address for `wan` itself, to learn whether the ISP
  hands one out.
- `ia_pd 2/::/56` asks for a delegated prefix, hinting at a /56: some ISPs
  give a /60 unless asked for more, and none gives more than it allows.
- The trailing `-` is what keeps it a probe. Without an interface after it,
  dhcpcd numbers **every other interface** from the delegation, iot and the
  tunnel included (`dhcpcd.conf(5)`, `ia_pd`). `-` delegates to none.

Configuring either `ia_` option makes dhcpcd start DHCPv6 when the link comes
up, whatever the RAs say (`DHCPCD_IA_FORCED` in its source), so the probe
asks even if the ISP never advertises. Nothing forwards and nothing
advertises, so no client sees a difference. dhcpcd installs an unreachable
route for the delegated prefix, which is how it is read below without
printing it.

At home, on trusted, at a time when the internet dropping for a minute
matters to nobody:

```
sudo nixos-rebuild test --flake github:nnorx/nix-config/ipv6-probe --accept-flake-config --refresh
```

`test` activates without touching the bootloader, so **a reboot is the
undo**. The change to `dhcpcd.conf` restarts dhcpcd, and with
`networking.dhcpcd.persistent` at its default of false a restart
deconfigures `wan` first: the house is offline for the seconds it takes to
re-lease. gate sends no client identifier, so the ISP keys the lease on
the `wan` MAC and normally hands the same IPv4 address back. `fleet_wan_addresses` and `fleet_wan_default_routes` in Grafana show
the lease going and coming back. SSH from trusted does not depend on `wan`,
so the session survives whatever the ISP does.

**deploy-guard is not armed for this, and does not need to be.** It rolls
back to the generation running when it was armed, at the next boot; after a
`test` that boot already runs the unchanged default generation. Armed before
the test, it would only add a second reboot after the first. Armed after it,
it refuses: the running system is in no generation, so it cannot name one.
If gate stops answering on trusted, which this change gives no reason to
expect, a power cycle is the undo.

Two minutes later, on gate, read lengths and counts only:

```
ip -6 route show type unreachable | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /\//) { split($i, a, "/"); print "delegated /" a[2]; next } }'
ip -6 -o addr show dev wan scope global | wc -l
ip -6 route show default dev wan | wc -l
ip -4 -o addr show dev wan scope global | wc -l
sudo dhcpcd --dumplease -6 wan | grep -E 'ia_pd.*(length|vltime|pltime)'
```

The first line is the decision; the rest are context: whether `wan` got an
address of its own, whether there is a default route, that the IPv4 lease
came back, and the delegation's lifetimes. If the first prints nothing,
dhcpcd's journal says why (`journalctl -u dhcpcd -b`), but its lines carry
the prefix, so mask before pasting anything:

```
journalctl -u dhcpcd -b | sed -E 's/[0-9a-f]{1,4}(:[0-9a-f]{0,4}){2,7}(\/[0-9]+)?/<v6>/g'
```

Then undo, by rebooting or, without a reboot, by re-activating the default
generation (dhcpcd restarts once more):

```
sudo /nix/var/nix/profiles/system/bin/switch-to-configuration test
```

What the result decides:

| Delegated | Then |
|---|---|
| Nothing | The plan stops at its docs PR. The item in router.md closes as "not offered", with the date, to check again after an ISP or plan change |
| /64 | One segment. trusted only, or decide it is not worth it |
| /60 | Sixteen subnets. Each segment that gets one is given a small `subnetId`, below |
| /56 or larger | 256 subnets. `subnetId` is the VLAN id, so a segment's IPv6 subnet carries its VLAN as its IPv4 third octet does |

Record in this file, with the date: the length, whether `wan` got its own
address, whether the ISP advertises a default route, and the lifetimes.
Never the prefix.

## The design

### Prefixes and advertisements

**dhcpcd takes the delegation, and corerad advertises it.** Both are
already the right shape for gate. dhcpcd is what holds the `wan` lease now,
and it assigns each named interface a /64 from the delegation by `sla_id`,
with gate at suffix `::1`. It activates an interface for delegation even
though NixOS's generated `denyinterfaces` names every LAN interface
(`dhcp6.c`, "activating for delegation"), and the VM test should show it does
nothing else there: no DHCPv4, no solicitations. corerad's `prefix = "::/64"`
advertises whatever /64 the interface holds, so its config names no prefix
either.

systemd-networkd could do both jobs in one daemon, and was passed over:
gate runs scripted networking, and moving it to networkd would rewrite the
interface layer of the house's only router for a feature that does not need
it.

In `lib/net.nix`, a segment opts in with a subnet id, and gate records the
length the probe found:

```nix
trusted = {
  id = 10;
  # ...
  ipv6.subnetId = 10;
};

gate = {
  # ...
  delegatedPrefixLength = 56;
};
```

A segment with a `subnetId` gets a /64 from dhcpcd and RAs from corerad; one
without gets neither. `modules/net-assertions.nix` checks that the ids are
unique and fit in `64 - delegatedPrefixLength` bits. Neither number
identifies the house: every customer on the same plan gets the same length.

dhcpcd keeps its reject route for the whole delegation, so traffic to an
unassigned subnet dies at gate rather than bouncing off the ISP.

### What each segment's clients get

RAs carry the autonomous flag and nothing else: no managed or other-config
flag, so no DHCPv6 server, and **no RDNSS**. Android does not do DHCPv6
addressing, so SLAAC is the only scheme every client supports, and DNS stays
where DHCPv4 already puts it (below).

| Segment | Prefix | Clients get | Policy over IPv6 |
|---|---|---|---|
| trusted | A /64 | SLAAC addresses, a default route via gate. DNS as now, from DHCPv4 | Internet. Into servers as on IPv4, though servers has no IPv6 to reach |
| guest | A /64, after trusted has run a while | The same. DNS from DHCPv4, the public resolvers | Internet only. IPv6 DNS to anyone is allowed, as on IPv4: guest is not redirected |
| work | A /64, only if wanted | The same. DNS from DHCPv4, the Pis | Internet. IPv6 port 53 and 853 out `wan` refused, so DNS falls back to IPv4 and is redirected and not logged, as now |
| iot | None | Nothing | Not planned. The egress design in [privacy.md](privacy.md#internet-for-iot) is IPv4, and every rule in it needs an `ip6` twin before iot gets an address. Until then iot has nothing to gain |
| servers | None | Nothing | Statically addressed infrastructure. The Pis recurse fine over IPv4, and F10 in privacy.md keeps the switch and AP off the internet in one family, not two |
| vpn | None | Nothing | See [the tunnel](#the-full-tunnel-profile) |

A segment without a prefix and without RAs still has gate forwarding IPv6
for it in principle, since forwarding is global. A device there that made up
an address would be dropped by the strict reverse-path filter unless the
address were in its own segment's subnet, and its own segment has none.

The work laptop is managed by someone else, and how its VPN client treats
IPv6 is its administrator's business. If work gets a prefix and the laptop
starts sending IPv6 around that VPN, that is the laptop's policy showing, not
gate's. Whether to give work a prefix at all is Nick's call; it gains
nothing it lacks today.

### Inbound: an explicit default deny

Without NAT, every addressed device is reachable from the internet as far as
gate lets it. gate's forward chain drops new inbound connections by default,
but nixpkgs accepts ICMPv6 in `forward-allow` ahead of every rule this repo
adds, echo requests included. So with forwarding on, as things stand,
anything on the internet could ping every device in the house, and the only
thing keeping TCP and UDP out is that no rule happens to let them in.

The deny is therefore its own base chain, in a table of its own, at a
priority ahead of nixpkgs' filter chain:

```
table inet gate-inbound {
  chain forward {
    type filter hook forward priority filter - 10;
    iifname "wan" meta nfproto ipv6 ct state new counter drop comment "nothing inside answers the internet"
  }
}
```

A drop in any base chain is final, so this holds whatever is later added to
`forward-allow`, a careless accept included. It touches only new flows:
replies and ICMPv6 errors for connections from inside, packet-too-big among
them, are `related` or `established` and pass. That matches IPv4, where NAT
means no device answers a ping from outside. gate itself still answers ping
on `wan`, as it does on IPv4. A port forward over IPv6, if one is ever
wanted, is an exception written into this chain.

### The DNS redirect and the 853 block

**The IPv6 half of the redirect is a refusal, not a redirect.** From every
segment the redirect covers (`redirectIfaces`), IPv6 port 53 out `wan` is
rejected the way 853 is: a TCP reset, ICMPv6 port-unreachable for UDP. A
client with a hardcoded IPv6 resolver gives up on it at once and tries the
next, and a device with hardcoded resolvers in both families falls back to
the IPv4 one, which the existing redirect catches. A device with an IPv6
resolver hardcoded and no IPv4 one loses DNS, like a phone in strict Private
DNS mode; none is known in the house.

A real IPv6 redirect, DNAT to the resolvers, was passed over. It needs the
Pis to hold IPv6 addresses, which come from a delegated prefix that cannot be
written into the rule, or from a ULA added to servers for this alone. And it
would break the two things the redirect is for: attribution, since privacy
addresses rotate daily, and the work segment's rule, below.

**The 853 refusal already covers IPv6.** Its rules in
`hosts/gate/routing.nix` match no address family, so once IPv6 forwards they
refuse it too. The VM test should say so rather than leave it to reading.

**AdGuard and Unbound keep answering over IPv4 only.** They answer AAAA
questions already, which is all a dual-stack client needs from them. Serving
over IPv6 would cost three things: the Pis would need IPv6 addresses, which
servers does not get; AdGuard would see clients under rotating privacy
addresses, so per-client statistics would fragment; and the work segment's
`ignore_querylog` client matches the segment's IPv4 subnet, and its IPv6
subnet comes from a delegated prefix that cannot be written into
`modules/adguardhome.nix`, so work's queries would start being logged. RAs
carry no RDNSS for the same reason, and because forge recognises home by the
resolvers DHCPv4 hands it (`hosts/forge/dns.nix`); an IPv6 resolver
arriving first in an RA would be one more input to that logic for no gain.

Unbound's `do-ip6` stays false everywhere. The Pis have no IPv6 to recurse
over, and on gate, which will hold addresses, recursing over IPv6 adds
nothing: authoritative servers that answer only over IPv6 are rare enough
that none has been missed. Its comment in `modules/unbound.nix` needs
rewording once gate asks for a prefix, since it says gate does not.

### The full-tunnel profile

forge's full-tunnel profile routes `::/0` into the tunnel, with a ULA
placeholder address so NetworkManager installs the route
(`hosts/forge/vpn.nix`). gate gives each peer an IPv4 /32 and nothing else in
its `allowedIPs`, and WireGuard drops any packet whose source is not in the
sending peer's `allowedIPs`. So IPv6 from forge enters the tunnel and dies at
gate: **blackholed, not leaked**. That holds after the house has IPv6,
because it never depended on the house having none. It depends on two
things, and the plan keeps both:

- **No peer gets an IPv6 address.** The WireGuard rules match `ip saddr`,
  which is complete only while that is true. An assertion in
  `hosts/gate/wireguard.nix` that every `allowedIPs` entry is IPv4 makes the
  day someone adds one fail at evaluation, with a message pointing at the
  `ip6` twins the "no exit" drop and the grants would need.
- **DDNS stays an A record.** `hosts/gate/ddns.nix` publishes no AAAA
  (`provider.ipv6 = "none"`), so forge always dials gate over IPv4, and the
  endpoint route never has to be excluded from the `::/0` the profile
  captures. gate's WireGuard will listen on its IPv6 addresses too once it
  has them; nothing dials them, and the port scan below should find it as
  quiet as on IPv4.

What the 2026-10-02 test could not distinguish, and the retest must: "no
IPv6 at all" was the right answer then and is now, but it was also what a
house with no IPv6 would produce whatever forge did. The retest, from a
network that has IPv6 (the phone's hotspot, Wi-Fi off), compares against
that network's own prefix: with the profile down, note the hotspot's /64;
with the full profile up, an IPv6 address-echo site must fail to load, and
no address forge holds or shows may be in that /64. Compare, do not paste.

Carrying IPv6 through the tunnel and out gate's `wan`, rather than
blackholing it, would mean a vpn subnet, a /128 per peer and `ip6` twins for
every WireGuard rule. It buys the travelling laptop nothing that Happy
Eyeballs falling back to IPv4 does not already give, so it is not planned.

### Where prefixes appear

A delegated prefix identifies the house as the WAN address does
([network.md](network.md#what-stays-out-of-this-repo)), and an ISP can change
it. It appears nowhere in the repo, and nothing is written so that it would
have to:

| Place | Holds |
|---|---|
| `lib/net.nix` | `subnetId` per segment and gate's `delegatedPrefixLength`: small numbers, the same for every customer on the plan |
| nftables rules | Interface names, and ranges that are the same in every house: `fc00::/7`, `fe80::/10`. Never a delegated prefix |
| dhcpcd and corerad config | Interface names, `sla_id`s, and corerad's `::/64`, which means "whatever this interface holds" |
| VM tests | The documentation prefix, `2001:db8::/32` (RFC 3849), for the fake ISP's delegation, as `tests/gate-dns.nix` uses RFC 5737 for IPv4 |
| Metrics | Lengths, counts and lifetimes from gate's facts. corerad labels its series with `prefix` and `router`, and core5's scrape drops both labels, so the store never holds either, as it drops the MAC from `node_network_info` |
| Commit messages, PR text, pasted logs | Nothing. dhcpcd's journal prints the prefix; mask it as above before pasting |

DHCPv6 tells the ISP nothing new: dhcpcd's DUID is built from the `wan`
MAC, which every DHCPv4 request already carries. F12 (#171) clears the
hostname and the vendor class in the `interface wan` block, which covers
DHCPv6's FQDN and vendor options as well as DHCPv4's, but no DHCPv6
exchange has happened yet to show it. The probe is the first, so check its
requests on the wire as #171's PR describes for DHCPv4, with `udp src port
546` and the DHCPv6 option names.

## Watching it

From gate's facts (the metrics PR below), alongside what #157 already
reports:

- `fleet_wan_ipv6_addresses` and `fleet_wan_ipv6_default_routes`, the IPv6
  twins of the IPv4 lease metrics.
- `fleet_wan_delegated_prefix_length`, 0 when there is none, and the
  delegation's remaining valid lifetime. A length that drops to 0 is a lost
  delegation; a lifetime that stops being renewed is one about to be lost.

From corerad, scraped by core5 on gate's servers address like the other
exporters: `corerad_interface_advertising` and `corerad_interface_forwarding`
per segment, `corerad_advertiser_misconfiguration` (corerad advertises a
router lifetime of 0, and flags it, on an interface that is not forwarding),
the advertised prefix lifetimes, and on `wan`, in monitor mode,
`corerad_monitor_messages_received_total` and the ISP's managed and
other-config flags.

conntrack is shared between the families, so `ConntrackPressure` covers IPv6
without change. node_exporter's per-interface bytes count both families
together. The inbound-drop and port-53-refusal counters are read with
`nft list chain inet gate-inbound forward` and `nft list chain inet nixos-fw
forward-allow` until nftables counters become metrics (privacy.md, the iot
PRs' step 5).

Once the alert rules exist (NNO-24): an alert when a segment with a
`subnetId` stops being advertised, or the delegation is gone for ten
minutes. If the ISP renumbers, clients keep their old addresses until
corerad's lifetimes run out, four hours preferred and a day valid by
default, and Happy Eyeballs carries them over IPv4 in the meantime.

## The port scan over IPv6

The checklist in router.md asks for it. From the phone's hotspot, Wi-Fi off,
WireGuard off, once trusted is advertising:

- `nmap -6 -Pn -p-` against gate's `wan` address (if the ISP gave it one) and
  against gate's `::1` on trusted's /64: every TCP port filtered.
  `nmap -6 -Pn -sU -p 53,123,443,546,547`: `open|filtered`, none `closed`,
  as on IPv4. UDP 443 is WireGuard, which answers nothing without a key.
- The same against a trusted client's current address: everything filtered,
  and `ping` gets no answer, which is the inbound chain at work.
- Before the first of these, list what gate binds to every address. The
  filter runs on gate and prints only wildcard binds:

  ```
  fleet-ssh gate "ss -Hlntu | awk '\$5 ~ /^(\[::\]|\*|0\.0\.0\.0):/ { print \$1, \$5 }'"
  ```

  On IPv4 the firewall is all that stands between such a socket and `wan`,
  and the same is true on IPv6; the scan confirms it rather than finding out.
  On 2026-10-12 the list was WireGuard's UDP 443 on both families, dhcpcd's
  DHCPv4 client on 68, and its DHCPv6 client on 546, all expected.

Record the results in router.md's checklist with the date, and no addresses.

## The PRs, in order

Each depends on the one before. gate PRs that change its firewall or its
forwarding go behind `deploy-guard` ([recovery.md](recovery.md)). None
changes a Pi except where it says so; where `lib/net.nix` changes, the PR
quotes preflight's brief on whether the Pis change with it.

1. **`docs/ipv6: plan ipv6 on gate`.** This file, and the pointer from
   router.md.
2. **`gate: accept router advertisements on wan only`.** `accept_ra = 0` and
   `autoconf = 0` on every LAN interface, named from `segmentOn` and the
   physical ports, plus `default` for interfaces created later. dhcpcd
   handles `wan`'s RAs itself, having set the kernel's off there, so `wan`
   is unaffected. Before it, read-only: whether gate holds any global IPv6
   address or route on a LAN interface today, as counts. A VM test reads
   each interface's sysctls. `nrs`; no firewall change.
3. **`gate: ipv6 state of wan as metrics`.** The facts above, in
   `hosts/gate/metrics.nix`, printing lengths and counts only, never an
   address. Before the probe, so the probe is on a graph. `nrs`.
4. **Hands-on, no PR to merge: the probe.** The `ipv6-probe` branch as a
   draft PR, closed after use, run as described above. Then
   **`docs/ipv6: what the isp delegates`** records the answer. If nothing is
   delegated, the plan ends here.
5. **`gate: ipv6 rules ahead of ipv6`.** Everything the firewall needs,
   landed while nothing forwards IPv6 so it changes no traffic: the
   `gate-inbound` chain; the IPv6 port-53 refusal beside the 853 rules,
   derived from `redirectIfaces`; `fc00::/7` in the upstream-management
   deny; and the IPv4-only assertion in `hosts/gate/wireguard.nix`, with
   `hosts/forge/vpn.nix`'s comment reworded, since gate will no longer lack
   IPv6. A new `tests/gate-ipv6.nix`, beside `tests/gate-dns.nix`: a fake ISP
   delegating from `2001:db8::/32` and advertising on the `wan` wire, gate
   from `hosts/gate/routing.nix` with forwarding switched on in the test
   alone, a client per segment and a host for the internet. It checks that
   the internet host can neither connect to nor ping a trusted client; that
   IPv6 port 53 and 853 from trusted are refused at once and from guest are
   not; that a source spoofed into another segment's subnet is dropped; and
   that IPv4 is unchanged. Firewall: behind `deploy-guard`.
6. **`gate: take a delegated prefix for trusted`.** `ipv6.subnetId` on
   trusted and `delegatedPrefixLength` on gate in `lib/net.nix`, with their
   assertions; dhcpcd's `ia_pd` built from them, plus `ia_na` if the probe
   found one offered. gate now holds a global address on trusted's /64 and
   perhaps on `wan`, but nothing forwards and nothing advertises, so no
   client changes. The comments in `modules/unbound.nix` and
   `hosts/gate/ddns.nix` that say gate has no IPv6 are reworded. dhcpcd
   restarts, so the house blips as in the probe: deploy in the morning,
   behind `deploy-guard`. Afterwards, the `ss` check and the scan of gate's
   own addresses, since gate is now globally addressed.
7. **`gate: forward ipv6 and advertise it on trusted`.** IPv6 forwarding by
   sysctl, **not** `networking.nat.enableIPv6`, which would also masquerade
   IPv6 behind gate. corerad advertising on every interface whose segment
   has a `subnetId`, monitoring `wan`, with its metrics bound to gate's
   servers address and opened to the collector alone, at a new
   `ports.corerad` in `lib/net.nix`. The VM test grows clients getting
   addresses and a route, and gate keeping its `wan` default route with
   forwarding on (dhcpcd takes `wan`'s RAs in userspace, so forwarding does
   not stop it, but the test should show it). `tests/forge-dns.nix` grows a
   home case whose RAs arrive before DHCPv4, as they will on trusted.
   Forwarding: behind `deploy-guard`.
8. **`core5: scrape gate's router advertisements`.** corerad in core5's
   targets, the `prefix` and `router` labels dropped at scrape, and a panel.
9. **Hands-on: a week on trusted.** The port scan, the tunnel retest, that
   AdGuard's log shows the same IPv4 client addresses as before, that the
   delegation's lifetime renews on the graph, and that a client's addresses
   are privacy addresses. Results into router.md's checklist, with dates.
10. **`gate: ipv6 on guest`.** Its `subnetId`, and guest cases in the VM
    test. `lib/net.nix` changes: quote preflight's brief.
11. **`gate: ipv6 on work`**, only if Nick wants it. After deploying, check
    that work's queries are still absent from AdGuard's log.
12. **`core5: alert when gate's delegation or advertisements stop`**, after
    NNO-24 has merged.

Not planned: iot, servers and the tunnel, each for the reason in its row
above. What would reopen iot is privacy.md's egress chain gaining `ip6`
twins, and a device there that needs IPv6.
