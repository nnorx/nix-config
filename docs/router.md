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
ssh gate 'sudo nft list chain ip nixos-nat dns-redirect'
ssh gate 'sudo nft list chain inet nixos-fw forward-allow'
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
