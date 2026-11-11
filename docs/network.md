# The network

What the house runs on, in the present tense. `gate` routes, two Pis resolve,
and a third runs the UniFi controller and Home Assistant. gate itself is
[router.md](router.md).

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
                    │  WireGuard, UDP 443 on wan │
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
                                  Unbound Unbound HA       SSIDs
                                                  metrics
```

## Segments

Six, defined once in [`lib/net.nix`](../lib/net.nix) and consumed everywhere
else by attribute name. The third octet carries the VLAN id, so an address
names its own segment; `vpn` is not a VLAN but keeps the convention. `gate`
holds `.1` in each. Below `.100` is reserved for statics and reservations,
`.100-.240` is the dynamic pool, `.241+` is left alone.

| VLAN | Segment | Subnet | Holds | Policy |
|---|---|---|---|---|
| 10 | trusted | 192.168.10.0/24 | Laptops, phones, the wired workstation | Full access. Port 53 redirected |
| 20 | servers | 192.168.20.0/24 | core4, core5, lifeline, switch, AP | Reachable from trusted. **No DHCP pool**: statically addressed. Not redirected |
| 30 | iot | 192.168.30.0/24 | Cameras, plugs, TVs, the Govee lamps | Internet, plus port 53 to the Pis. Govee's LAN API with Home Assistant, per [`hosts/gate/govee.nix`](../hosts/gate/govee.nix). Port 53 redirected |
| 40 | guest | 192.168.40.0/24 | Visitors | Internet only, public resolvers. Not redirected |
| 50 | work | 192.168.50.0/24 | One managed laptop | Internet, plus port 53 to the Pis. Port 53 redirected, and not logged |
| none | vpn | 192.168.60.0/24 | WireGuard peers on `wg0`, one fixed address each: forge `.10`, phone `.20` | Per peer, from `segments.vpn.grants` in [`lib/net.nix`](../lib/net.nix), which [`hosts/gate/wireguard.nix`](../hosts/gate/wireguard.nix) renders. Every peer gets port 53 to the Pis; forge adds the AdGuard UI, SSH to the fleet and internet. Port 53 redirected |

"Port 53 redirected" means plaintext DNS aimed anywhere else is rewritten to
the fleet's resolvers ([DNS](#dns)). Everything not in the policy column is
refused by the default-drop forward chain, so `guest` is isolated by not
appearing in the ruleset at all.

"Internet" is the nat module's accept out `wan`. iot's passes the trial set
in [privacy.md](privacy.md#internet-for-iot) first.

**192.168 rather than 10.x**, because a managed VPN client on one laptop
routes a wide slice of 10/8 into its tunnel, which would make the house
unreachable from it whenever the tunnel is up.

**`servers` carries no DHCP pool**, so the devices the rest of the network is
reached through are statically addressed, and Kea stays off the trunk parent: `servers` is the untagged VLAN on `lan0`, and a raw socket there
also receives tagged frames, so an iot device's request would arrive on both
`lan0.30` and `lan0` and the `lan0` copy would be answered from the wrong pool.
Serving DHCP only where a segment declares a pool means nothing binds `lan0`.

**`work` is segmented in both directions.** Its software is administered by
someone else, so it does not share a segment with the house, and the house's
devices do not reach it.

## Ports on gate

| Port | Socket | Role |
|---|---|---|
| `wan` | ETH0 | The modem. The only address here that is not ours to choose |
| `lan0` | ETH1 | 802.1Q trunk to the Flex switch. Untagged is `servers` |
| `lan1` | ETH2 | Untagged, bridged into `br-trusted`: a dedicated 2.5G run |
| `lan2` | ETH3 | Spare, left down |

Rules name `wan` and `lan0`, never `enp2s0`: the NICs are renamed by PCI path
([router.md](router.md#hardware)), so a change in systemd's predictable naming
cannot swap WAN and LAN under the ruleset.

`lan1` is bridged with the tagged trusted VLAN into `br-trusted` rather than
given a subnet, so a machine cabled to gate shares mDNS with the phones and
laptops, and printer and cast discovery work.

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

This is the bootstrap path. A UniFi switch's management rides the untagged
native VLAN, and a factory reset returns it there, so with no untagged address
on gate a reset switch has no path to the controller. Tagging every segment
has stranded the switch, needing hands on it to recover.

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
them, so each query reaches AdGuard from its client's own address, which
per-client stats and rules need. `networking.nat` masquerades only outbound on
`wan`, so the source survives the forward chain. `guest` gets public
resolvers instead.

**gate resolves through its own Unbound on loopback**, recursing, so it can
be rebuilt with both Pis down. core5 uses public resolvers for the same shape
of reason: it monitors the resolvers ([observability.md](observability.md)).
Every fallback names two operators, Cloudflare and Quad9, and never Google.

**Clients with hardcoded resolvers are redirected.** gate's `dns-redirect`
chain rewrites plaintext port 53 from the segments the table marks, whatever
address it was aimed at, to core4 or lifeline, spread across the two.

This is the rule the `servers` segment exists to make possible: a DNAT to a
resolver on a different subnet keeps the client's source address, because the
reply returns through gate and conntrack undoes the translation. On the same
subnet it would not, which is why `servers` is excluded, and why the exclusion
is derived from where the resolvers sit rather than written out. `servers` also
carries the Pis' own recursion, which must reach authoritative servers on port
53 untouched. `guest` is excluded because it is not on the fleet's resolvers at
all.

`work` is redirected and filtered, but not logged (`logQueries = false`;
[privacy.md](privacy.md#what-the-resolvers-keep)).

**Local names.** Kea does not register hostnames with AdGuard. Unbound
answers NXDOMAIN for the suffixes devices invent for local names (`lan`,
`local`, `home.arpa` and others, in `modules/unbound.nix`), so those lookups
stop at the resolver.

**DoT and DoQ are refused, so devices that fall back are redirected.** From
the same segments the redirect covers, gate rejects TCP and UDP 853 out `wan`,
with a reset or port-unreachable so the client falls back at once rather than
timing out. A device that tries encrypted DNS first and then plaintext ends up
on the fleet. One that never falls back, like an Android phone with Private
DNS in strict mode, loses DNS instead. A segment whose devices need DoT goes
in `dotExempt` in `hosts/gate/routing.nix`, which gives it 853 back and keeps
its port 53 redirected. [router.md](router.md#checking-the-dns-rules) has the
check.

**DoH is set by browser policy**, not the firewall: it rides 443, and endpoint
lists change ([privacy.md](privacy.md#forge)).

## What stays out of this repo

This repo is public. Three kinds of thing do not belong in it.

**Secrets, which sops handles.** WireGuard private keys, DDNS API tokens, the
AdGuard admin hashes, the UniFi MongoDB password, any PSK. `sops-nix` renders
these at activation, so the Nix store holds ciphertext or a sentinel rather than
the value. See the secrets section in the [README](../README.md).

**Identifying data, which is not secret but is a map to one specific house.**
The WAN address, the DDNS hostname, SSIDs (wigle.net maps SSIDs to places),
NIC MAC addresses, and above all a reservation table, which pairs every device
with a vendor OUI. None of it is secret; all of it maps one house.

RFC1918 addresses alone are fine in public. A per-device MAC table is not, so
reservations split along that line ("Naming a device", below).

**Anything the UniFi controller exports.** Backups carry Wi-Fi PSKs and device
credentials. They stay off the repo entirely, encrypted or not. See
[unifi.md](unifi.md).

### Naming a device

A rule that names one device needs a stable address, and on iot that is a Kea
reservation, keyed on a MAC. So a device has two halves:

| Half | What | Where |
|---|---|---|
| What a rule reads | A role name, a segment, an address | `devices` in `lib/net.nix` |
| What binds the address to hardware | The MAC | `mac-<name>` in gate's sops file, read by Kea alone |

A role name says what a rule needs and no more: no model, no room. `govee-1` is
fine, since `hosts/gate/govee.nix` already says the house has Govee lights. A
device whose existence alone should not be public gets no reservation, and the
pool serves it.

Addresses sit below the segment's pool, in the range reserved for statics and
reservations. A rule reads a role through a named list, such as `goveeLights`.
`modules/net-assertions.nix` checks that each device's segment has a pool, that
its address is outside the pool and not the gateway, and that no address is
shared. Nothing that builds from this repo needs a credential: there is no
private flake input, and sops decrypts on gate at activation.

### Already disclosed

Encrypting a value later does not unpublish it. A credential that has been in
this repo's history (two AdGuard admin hashes, and the old `initialPassword`)
is rotated, not re-encrypted: the value has to be new. Putting the hash of a
published password into sops would only wrap it.

## Renumbering

A one-file change: consumers reference attribute names in `lib/net.nix`.

[`modules/net-assertions.nix`](../modules/net-assertions.nix) checks the file
agrees with itself, and is imported by `hosts/common` so every host validates
the whole topology rather than only its own entry: a host's address inside the
segment it names, `subnet` and `prefixLength` stating the same prefix, gateways
and pools inside their own subnets, and every `metricsTargets` entry being a
host the collector can scrape on its own segment.

What it cannot check is whether the file agrees with the *switch*. Port
profiles live in the UniFi controller's database, so a new tagged segment needs
adding there by hand or devices on it silently get no lease.
