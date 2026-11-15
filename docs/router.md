# gate

`gate` is a CWWK N100 with four Intel i226 NICs, and the house's only router.
[network.md](network.md) has the network it routes. There is no fallback
router, so the recovery USB and `deploy-guard` are the ways back from a bad
deploy ([recovery.md](recovery.md)). gate deploys by hand. Its validation
checklist is in Linear's Net Security project.

## Hardware

- **Ports.** Sockets ETH0 to ETH3 are `enp2s0` to `enp5s0` in PCI order.
  systemd `.link` files rename them by PCI path (`hosts/gate/default.nix`),
  which survives a change in predictable naming and keeps MACs out of the
  repo.
- **i226-V link flapping.** ASPM-related drops are common on these NICs. If
  links flap, `pcie_aspm=off` is the usual fix. `ethtool` and `pciutils` are
  installed for this.
- **Thermals.** The fanless chassis runs warm. `sensors` under sustained load.

## WAN

`wan` takes a public, routable IPv4 address from the ISP over DHCP, so the
tunnel is plain inbound WireGuard. To check again, after an ISP change for
instance:

```
ssh gate 'ip -4 -br addr show wan; ip route | head -1'
```

An address in `100.64.0.0/10` would mean CGNAT, which inbound WireGuard
cannot cross; a coordination service such as Tailscale would be the answer
then. gate drops that range upstream with the private ones.

The house has no global IPv6: gate asks for no prefix delegation and sends no
router advertisements, and Unbound recurses over IPv4 alone. The IPv6
project in Linear plans it.

## What gate is watched for

core5 scrapes gate ([observability.md](observability.md),
`hosts/gate/metrics.nix`) for the questions a router fault raises before
anyone notices the internet is broken: WAN link and lease, conntrack
pressure, per-interface throughput, Kea's pools, and each tunnel peer's last
handshake. The resolvers' DNS failures come from core4 and lifeline.
`tests/gate-metrics.nix` checks the answers carry no WAN address.

## Checking the DNS rules

network.md's DNS section has how the port 53 redirect and the 853 refusal
work. After a deploy that touches them, from a trusted client, in one
sitting:

```
kdig +tls @1.1.1.1 example.com            # fails at once, connection refused
dig @1.1.1.1 <a name the fleet filters>   # the fleet's blocked answer
ssh -t gate 'sudo nft list chain ip nixos-nat dns-redirect'
ssh -t gate 'sudo nft list chain inet nixos-fw forward-allow'
```

`kdig` failing after a pause rather than at once means the packets are
dropped somewhere, not rejected by this rule. The redirect's counter and the
two `dport 853` counters should be non-zero. Read them in the same sitting:
the nftables unit recreates the table on every reload, so any later switch
that changes the ruleset zeroes them, which reads the same as never matching.
`tests/gate-dns.nix` checks the rules against the real ruleset in VMs.

## Inbound remote access

SSH into the fleet and filtered DNS from away, over WireGuard terminating on
gate (`hosts/gate/wireguard.nix`, `hosts/forge/vpn.nix`). README, "Remote
access", has the setup.

- **Plain WireGuard, not Tailscale or Headscale.** gate has a routable
  address, so a coordination server has nothing to solve, and either adds a
  party that can enroll devices. Nothing expires a WireGuard key, so revoking
  a peer is deleting it and deploying gate.
- **UDP 443**, not 51820: restrictive Wi-Fi blocks unusual UDP ports more
  often than the one HTTP/3 uses. WireGuard answers nothing without a valid
  key, so a WAN port scan finds nothing listening.
- **Per-peer policy.** Peers get fixed addresses on the `vpn` segment, and
  what each reaches is `segments.vpn.grants` in `lib/net.nix`. forge gets
  DNS, the AdGuard UI and SSH to the fleet; the phone, DNS alone. Neither gets
  the UniFi UI.
- **forge's two profiles.** Split, the default, carries the home subnets and
  DNS. Full tunnel is for untrusted networks: it moves what the local network
  sees to the home ISP, bounded by the home upload. The phone is split only,
  with `PersistentKeepalive = 25` for carrier NAT.
- **MTU 1280**, not WireGuard's 1420: over a phone hotspot larger packets
  vanished while the handshake and pings worked. `vpnMtu` in `lib/net.nix`
  has the measurement. Test from a hotspot with the phone's own Wi-Fi off, or
  a tethered laptop goes out through the house.
- **Keys** follow the SSH model: each peer's private key is made on its
  device, public halves in the repo, gate's key and a PSK per peer in sops
  ([keys.md](keys.md#wireguard)).
- **The endpoint name.** gate updates an A record on Cloudflare
  (`hosts/gate/ddns.nix`), DNS only, since Cloudflare's proxy carries no UDP.
  The hostname lives in sops, as a random label, and never gets a TLS
  certificate, since certificate transparency logs publish every name one is
  issued for.

gate's firewall changes go behind `deploy-guard`.

## Exit tunnel

`wg-exit` is gate's WireGuard client to one VPN provider server
(`hosts/gate/exit.nix`). A segment in `exitSegments` (`lib/net.nix`) leaves
through it instead of `wan`, and through nothing while it is down. Each
segment is turned on in a deploy of its own; work and servers never are.
The provider's key, its endpoint and gate's inner address are in sops alone.

| Piece | What it does |
|---|---|
| `ip rule` 1000 | `lookup main suppress_prefixlength 0`: the house's own routes win |
| `ip rule` 1100 | `iif <segment's interface> lookup exit`, one per tunneled segment |
| Table `exit` (100) | `default dev wg-exit`, then `unreachable default metric 100` |
| `exit-routing.service` | Sets the three above before `network-pre.target`, reconciling the 1100 rules on every start |
| `exit-tunnel.service` | Makes `wg-exit` from the rendered `exit-tunnel.conf`, MTU 1420 |
| `forward-allow` | Out `wg-exit` for tunneled segments; out `wan` dropped into `exit-leak-dropped` |
| `exit-masquerade`, `exit-mss` | NAT to gate's inner address; MSS clamped to the tunnel's MTU |

gate's own traffic matches no `iif` rule, so wg0, NTP, DNS, DDNS and the
tunnel's own packets stay on `wan`. A tunneled client's packet for an address
on `wan`'s own subnet takes `main`'s connected route and is dropped and
counted. Reverse-path filtering stays strict but for `wg-exit`, whose replies
come from addresses `main` routes to `wan`, though never from a house address.

**Keys and server.** From the repo, in your own terminal, inside
`nix shell nixpkgs#sops nixpkgs#jq nixpkgs#wireguard-tools`. The private key is made on gate, straight into sops; the
second line prints its public half. Register that as a device in the
provider's account with DNS hijacking off, and note its inner address.
Then paste the server's public key, its `address:port`, and the inner
address with `/32` at each silent prompt:

```bash
ssh gate wg genkey | jq -R . | sops set --value-stdin secrets/gate.yaml '["exit-private-key"]'
sops decrypt --extract '["exit-private-key"]' secrets/gate.yaml | wg pubkey
for k in exit-primary-public-key exit-primary-endpoint exit-address; do printf '%s: ' "$k"; read -rs v && echo && printf '"%s"' "$v" | sops set --value-stdin secrets/gate.yaml "[\"$k\"]"; done; unset v k
for k in exit-private-key exit-primary-public-key; do sops decrypt --extract "[\"$k\"]" secrets/gate.yaml | grep -qE '^[A-Za-z0-9+/]{43}=$' && echo "$k ok"; done
sops decrypt --extract '["exit-primary-endpoint"]' secrets/gate.yaml | grep -qE '^[0-9.]+:[0-9]+$' && echo "endpoint ok"
sops decrypt --extract '["exit-address"]' secrets/gate.yaml | grep -qE '^[0-9.]+/32$' && echo "address ok"
```

Activation fails while any is missing. Deploy with `nrs` behind deploy-guard
(recovery.md), and confirm only once `fleet-ssh` answers from every host.

**Checks.** After a deploy, and when the tunnel is in doubt:

```bash
ssh -t gate 'h=$(sudo wg show wg-exit latest-handshakes | cut -f2); echo "handshake $(( $(date +%s) - h ))s ago"'
ssh -t gate 'sudo nft list counter inet nixos-fw exit-leak-dropped; ip rule; ip route show table exit'
```

The handshake should be under two minutes old, and the counter 0, though
any ruleset reload zeroes it. For throughput, run Ookla's CLI from `ssh -t
gate`, bound to each way out in turn, printing only ping and speeds:

```bash
NIXPKGS_ALLOW_UNFREE=1 nix shell --impure nixpkgs#ookla-speedtest nixpkgs#jq
for i in wg-exit wan; do speedtest --accept-license --accept-gdpr -I $i -f json | jq -c --arg i $i '{via: $i, ping: .ping.latency, down: (.download.bandwidth * 8 / 1e6), up: (.upload.bandwidth * 8 / 1e6)}'; done
```

## An address on the wrong wire

An address on the wrong wire fails silently, and in one direction. During
the VLAN cutover each Pi held its flat-LAN address beside its segment
address, which kept it reachable while the switch uplink moved. Once its
port carried the servers VLAN, the flat address answered nothing but kept its
directly connected route, so the Pi sent everything for the old subnet onto
the servers VLAN rather than through gate. The symptom was the controller
reporting the switch unreachable while gate pinged it fine.

Dual addressing is the right tool during a cutover and a liability the moment
it finishes. Retire the old address in the same session that completes the
move.
