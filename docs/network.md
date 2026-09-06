# The network

What the house runs on, in the present tense. `gate` routes, two Pis resolve,
and a third runs the UniFi controller. For how it got here and what is still
open, see [router.md](router.md).

```
                              internet
                                  │
                            ┌─────┴─────┐
                            │   modem   │
                            └─────┬─────┘
                                  │  wan   DHCP from the ISP
                    ┌─────────────┴──────────────┐
                    │            gate            │
                    │    CWWK N100, 4x i226      │
                    │  nftables · NAT · Kea      │
                    │  Unbound on 127.0.0.1:53   │
                    │  holds .1 in every segment │
                    └───┬────────────────────┬───┘
                 lan1   │                    │   lan0
              untagged  │                    │   802.1Q trunk
               trusted  │                    │   untagged: servers
                        │                    │   tagged:   10 30 40 50
              ┌─────────┴────────┐   ┌───────┴──────────────┐
              │  wired machine   │   │  Flex switch, PoE    │
              │  2.5G, bridged   │   │  192.168.20.2        │
              │  into br-trusted │   └─┬─────┬─────┬──────┬─┘
              └──────────────────┘     │     │     │      │
                                    core4  life  core5   U7 Pro
                                      .32   .11    .49    .20.3
                                       │     │      │       │
                                  AdGuard AdGuard UniFi   tagged
                                  Unbound Unbound pimon    SSIDs
```

## Segments

Five, defined once in [`lib/net.nix`](../lib/net.nix) and consumed everywhere
else by attribute name. The third octet carries the VLAN id, so an address
names its own segment. `gate` holds `.1` in each. Below `.100` is reserved for
statics and reservations, `.100-.240` is the dynamic pool, `.241+` is left
alone.

| VLAN | Segment | Subnet | Holds | Policy |
|---|---|---|---|---|
| 10 | trusted | 192.168.10.0/24 | Laptops, phones, the wired workstation | Full access |
| 20 | servers | 192.168.20.0/24 | core4, core5, lifeline, switch, AP | Reachable from trusted. **No DHCP pool**: statically addressed |
| 30 | iot | 192.168.30.0/24 | Cameras, plugs, TVs | Internet, plus port 53 to the Pis |
| 40 | guest | 192.168.40.0/24 | Visitors | Internet only, public resolvers |
| 50 | work | 192.168.50.0/24 | One managed laptop | Internet, plus port 53 to the Pis |

Everything not named in the policy column is refused by the default-drop
forward chain rather than by a deny rule, so `guest` is isolated by not
appearing in the ruleset at all.

**192.168 rather than 10.x, for a concrete reason.** A centrally managed VPN
client on one of the laptops here routes a wide slice of 10/8 into its tunnel.
Numbering the house inside that range would have made every device at home
unreachable from that machine whenever the tunnel was up, and the policy is not
ours to change locally. Managed profiles rarely claim 192.168, because that is
where home networks live.

**`servers` carries no DHCP pool, and that absence is load-bearing twice.**
Everything on it is statically addressed, which is a better property for the
devices the rest of the network is reached through. It also keeps Kea off the
trunk parent: `servers` is the untagged VLAN on `lan0`, and a raw socket there
also receives tagged frames, so an iot device's request would arrive on both
`lan0.30` and `lan0` and the `lan0` copy would be answered from the wrong pool.
Serving DHCP only where a segment declares a pool means nothing binds `lan0`.

**`work` is segmented in both directions.** Its software is administered by
someone else and cannot be audited from here, so on trusted it could enumerate
every device in the house. Equally, the house's iot chatter has no business
reaching a machine held to a security policy that is not ours.

## Ports on gate

| Port | Socket | Role |
|---|---|---|
| `wan` | ETH0 | The modem. The only address here that is not ours to choose |
| `lan0` | ETH1 | 802.1Q trunk to the Flex switch. Untagged is `servers` |
| `lan1` | ETH2 | Untagged, bridged into `br-trusted`: a dedicated 2.5G run |
| `lan2` | ETH3 | Spare, left down |

The NICs are renamed by systemd `.link` files matched on **PCI path**, not MAC
address. That defends against what actually reorders interfaces, which is
systemd's predictable-naming scheme changing between releases, while keeping
hardware identifiers out of a public repo. A rule naming `wan` stays correct
across such a change; a rule naming `enp2s0` is correct only until it is not,
and a silent WAN/LAN swap under a permissive ruleset is the expensive version
of that mistake.

`lan1` is bridged with the tagged trusted VLAN into `br-trusted` rather than
given a subnet of its own, so a machine cabled directly to gate shares a
broadcast domain with the phones and laptops. Separate subnets would break mDNS
between them, which surfaces later as printer and cast discovery quietly not
working.

## Switch topology

| Port | Contents |
|---|---|
| 5, 6, 7 | core4, lifeline, core5. Factory default, untagged |
| 8 | U7 Pro. Default native, **tagged** trusted, iot, work, guest |
| 9 | gate `lan0`. Default native, **tagged** trusted, iot, work, guest |

Switch management is static at `192.168.20.2`, the AP at `192.168.20.3`.

**The invariant that keeps this working: the untagged VLAN carries `servers`,
and nothing that has to be reachable in its default state lives on a tag.**
gate maps untagged traffic on `lan0` to `192.168.20.0/24`, so any
factory-defaulted device appearing on any port is immediately addressable.
Segments that exist for clients rather than infrastructure are tagged and reach
gate as `lan0.10`, `lan0.30`, `lan0.40` and `lan0.50`.

This asymmetry is not untidiness, it is the bootstrap path. Both attempts to
tidy it into "every segment is tagged" produced a deadlock where a reset device
could be neither reached nor adopted, and both needed physical intervention to
escape. A UniFi switch's own management interface rides the untagged native
VLAN, and a factory reset returns it there no matter what it was set to before.
If gate carries no untagged address, a reset switch has no path to the
controller.

The corollary is that **port profiles must leave the native network alone.**
Setting a port's native network to the `servers` *network object* puts its
traffic on VLAN 20, which splits it from the switch's own management on VLAN 1
and from every port still on the default. gate does not care what the switch
calls the untagged VLAN: anything arriving untagged on `lan0` is
`192.168.20.0/24` to it. Add only tagged networks to the AP and gate uplink
ports; leave everything else on the factory default.

## DNS

core4 and lifeline are each self-contained and share no state, so either can
serve the house alone. AdGuard Home filters on `:53` and forwards to that same
host's Unbound on `127.0.0.1:5335`, which recurses from the root servers with
DNSSEC validation. Neither depends on the other.

Kea hands clients **both Pi addresses directly** rather than gate proxying to
them. Proxying costs per-client attribution: every query would arrive from the
gateway address, so per-client stats, per-client rules and per-client rate
limits all stop working, and that is most of the reason to run AdGuard rather
than a plain blocklist. `guest` gets public resolvers instead, which is what
makes "internet only" true rather than aspirational.

Attribution works because `networking.nat` masquerades only outbound on `wan`.
A query from a client segment to a Pi crosses the forward chain with its source
address intact.

**gate resolves through its own Unbound on loopback, independent of the Pis.**
If `/etc/resolv.conf` pointed at them and they were down, `nixos-rebuild` could
not resolve `github.com`, so the router could not be fixed by rebuilding it.
That bootstrap loop is the entire reason it is there, and why it recurses
rather than forwarding somewhere.

core5 uses public resolvers for the same shape of reason: it runs the pimon
collector, so pointing it at core4 or lifeline would make monitoring depend on
the thing it monitors.

Two operators everywhere a fallback appears, Cloudflare and Quad9, so a single
provider outage does not take bootstrap with it. Google is deliberately absent:
keeping them out of the DNS path is one of the reasons this fleet exists.

**Local name resolution is a gap.** Kea does not register hostnames with
AdGuard. Static reservations in `lib/net.nix` plus AdGuard rewrites for the
handful of names worth having is the intended answer, and it keeps the topology
in one file.

**DoH is advisory, not enforceable.** Port 853 and known DoH endpoint IPs can be
blocked, but browsers ship encrypted DNS over 443 and the endpoint lists change.
Browser policy is more reliable than firewall rules here.

## What stays out of this repo

This repo is public and worth keeping that way. The module logic, the firewall
rules and the reasoning behind the topology are the useful part, and a ruleset
that is only correct while nobody has read it was never correct. Three kinds of
thing do not belong here.

**Secrets, which sops handles.** WireGuard private keys, DDNS API tokens, the
AdGuard admin hashes, the UniFi MongoDB password, any PSK. `sops-nix` renders
these at activation, so the Nix store holds ciphertext or a sentinel rather than
the value. See the secrets section in the [README](../README.md).

**Identifying data, which is not secret but is a map to one specific house.**
The WAN address, the DDNS hostname, SSIDs (wigle.net maps SSIDs to physical
locations), NIC MAC addresses, and above all a Kea reservation table, which is
an inventory of every device in the house paired with a vendor OUI. None of it
is cryptographically sensitive. All of it turns "a well-built router config"
into "Nick's house, and what is in it."

RFC1918 addresses alone are fine in public. A per-device MAC table is not.
`lib/net.nix` anticipates this: consumers reference attribute names rather than
values, which keeps open the option of moving the file into a private flake
input without editing anything that reads it. That option gets exercised when
reservations arrive.

**Anything the UniFi controller exports.** Backups carry Wi-Fi PSKs and device
credentials. They stay off the repo entirely, encrypted or not. See
[unifi.md](unifi.md).

### Already disclosed

Encrypting a value later does not unpublish it. Three things have been in this
public repo's history and should be treated as disclosed rather than fixed:

- **core4's AdGuard admin hash**, `$2y$05$...`, committed 2026-02-25 and moved
  to sops in #32. Cost 05 is 32 rounds, which is cheap enough to attack offline
  with a wordlist. This one wants rotating, not just encrypting.
- **lifeline's AdGuard admin hash**, `$2b$10$...`, committed 2026-08-23, same
  fix in #32. Cost 10 is far better, but it has been public just as long.
- **`initialPassword = "changeme"`** in `hosts/common`. With
  `wheelNeedsPassword = true` in the baseline this is the console *and* sudo
  password on any host where it was never changed. SSH is key-only, so it is
  not a remote entry point, but it is a free privilege escalation to anyone who
  already has a shell or the console.

Rotation is the remedy for all three, and rotating means changing the
credential, not re-encrypting the old one.

## Renumbering

Still a one-file change. The schema lives in `lib/net.nix` and consumers
reference attribute names, so moving a segment means editing that file alone.

[`modules/net-assertions.nix`](../modules/net-assertions.nix) checks the file
agrees with itself, and is imported by `hosts/common` so every host validates
the whole topology rather than only its own entry: a host's address inside the
segment it names, `subnet` and `prefixLength` stating the same prefix, gateways
and pools inside their own subnets, and every `pimonAgents` entry being a host
with an address.

What it cannot check is whether the file agrees with the *switch*. Port
profiles live in the UniFi controller's database, so a new tagged segment needs
adding there by hand or devices on it silently get no lease.
