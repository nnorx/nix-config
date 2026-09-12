# The gate build

`gate` is a CWWK N100 with four Intel i226 NICs. It replaced the Google Nest as
the house router at the Phase 7 cutover on **2026-09-05**. The goals, in order,
were multi-gig routing on the LAN side, getting Google out of the network path,
and remote access into the fleet. The first two are done; the third is Phase 8.

This is the build record and the list of what is still open. For the network as
it stands, see [network.md](network.md).

**There is no rollback.** The Nest is gone, so reverting means sourcing another
router. That was not the plan going in, where the Nest was to be kept unreset
as a revert path, and it raises what a bad deploy costs: the recovery USB and
`deploy-guard` are now the only ways back. See [recovery.md](recovery.md).

## Still open

- [ ] **Port-53 DNAT redirect for hardcoded resolvers.** Written but **not
      deployed and never observed matching**, so this stays open until the
      checklist items below have been run. It is the `dns-redirect` chain in
      `hosts/gate/routing.nix`: a query to any resolver other than the fleet's,
      from trusted, iot or work, is rewritten to core4 or lifeline with the
      client's source address intact. The servers segment was paid for to make
      exactly this possible.

      servers and guest are excluded, each for its own reason, and the
      exclusion is derived from where the resolvers actually sit rather than
      listed, so it follows them if one ever moves.

      The `work` segment is redirected like the others, and
      `modules/adguardhome.nix` gives it a persistent client with
      `ignore_querylog`, so that machine is filtered without being recorded.
      Before the redirect existed, a machine there ignoring DHCP was unlogged
      only because it was not talking to the fleet at all; that is no longer
      the reason, so the property is now written down instead of incidental.

      It catches plaintext DNS only. A device speaking DoT (853) or DoH (443)
      still bypasses the fleet's resolvers, and DoH is not distinguishable from
      other HTTPS traffic at the firewall. Blocking 853 outbound would push
      DoT-capable devices back onto port 53 where this rule catches them; that
      is not done here.

      It also cannot help a host that recurses for itself. The rule excludes
      whole segments, and the only recursers in the fleet (gate and the two
      Pis) are already outside it, but a workstation running its own resolver
      on trusted would have its queries to authoritative servers rewritten.
- [ ] **Confirm AdGuard logs real client IPs** rather than the gateway. The
      mechanism is in place (Kea hands out the Pi addresses directly, and nat
      masquerades only outbound on `wan`), but it has not been verified against
      the query log.
- [ ] **Is gate behind CGNAT?** Deferred from Phase 0 and now a one-liner,
      since gate reads its own WAN address:

      ```
      ssh gate 'ip -4 -br addr show wan; ip route | head -1'
      ```

      A routable address means Phase 8 remote access is inbound WireGuard.
      `100.64.0.0/10` means it is Tailscale. Nothing else depends on it.
- [ ] **Service tier actually purchased**, for the WAN speed test below.
- [ ] Static reservations in `lib/net.nix` for anything that needs a stable
      address. The switch and AP have statics set in the controller instead,
      which is where the rest of their config lives anyway. Reservations are
      keyed on MAC addresses, which do not go in this repo, so this arrives
      with the private input if it arrives at all.

### Validation checklist

These are the tests that distinguish a network that works from one that
happens to be working. The DNS half was run on **2026-09-12** and is recorded
below. The throughput, segmentation and gate-reboot items are still open.

- [ ] `iperf3` between two clients on different VLANs, forwarded through gate,
      confirming the routing path does multi-gig rather than just the links
      negotiating at 2.5G
- [ ] WAN speed test matching the service tier
- [ ] External port scan of the WAN address showing nothing listening
- [x] `dnssec-failed.org` fails to resolve, proving DNSSEC validation is live.
      2026-09-12: SERVFAIL on both resolvers, against Unbound directly on 5335
      and through AdGuard on 53. A signed control zone returns NOERROR with the
      `ad` flag, so this is validation rather than a coincidental failure
- [x] A DNS leak test showing the fleet's resolver, not the ISP's. 2026-09-12:
      both resolvers recurse from gate's own WAN address as seen by an
      authoritative server, so nothing forwards through the ISP
- [x] One Pi powered off, house still resolves. 2026-09-12: core4 powered
      down, 10/10 queries answered from a DHCP-configured client. Median
      latency rose from roughly 580 ms to 880 ms on uncached names, which is
      the stub failing over rather than anything breaking
- [ ] `gate` rebooted, everything returns with no manual intervention,
      including Kea leases and the WAN lease
- [ ] iot cannot reach trusted; guest cannot reach anything
- [ ] A client with DNS hardcoded to 8.8.8.8 still resolves, its queries appear
      in AdGuard under the client's own address, and a filtered domain is
      blocked for it. Then read the counter:

      ```
      ssh gate 'nft list chain ip nixos-nat dns-redirect'
      ```

      A counter still at zero means the rule is not on the path it was believed
      to be on. **Read it in the same sitting as the test.** The nftables unit
      deletes and re-adds the table on every reload, so any later
      `nixos-rebuild switch` that changes the ruleset resets the counter to
      zero, which reads identically to the rule never having matched.

      Partly done. 2026-09-12, from a trusted-segment client: queries sent to
      8.8.8.8, 1.1.1.1 and 9.9.9.9 all came back with the fleet's blocklist
      answer for a filtered domain while unfiltered names resolved normally,
      so the rewrite is on the path for all three. The two halves still open
      are the counter read, which needs root, and confirming the queries land
      in AdGuard under the client's own address rather than the gateway's
- [x] The Pis still resolve. Their own Unbound recursion leaves from the
      servers segment, which the redirect excludes, and getting that wrong
      takes DNS down completely rather than degrading it. Confirmed
      2026-09-12
- [ ] Nothing from the work segment appears in AdGuard's query log, which is
      what `logQueries = false` in `lib/net.nix` is meant to guarantee now that
      the segment is redirected rather than bypassing the fleet
- [x] One Pi powered off, and a client with a **hardcoded** resolver still
      resolves. This is a different test from the one above: a DHCP-configured
      client holds both resolver addresses and fails over in its own stub,
      while a redirected client has its destination chosen per connection by
      `numgen`, so roughly half its queries dead-end and rely on a retry
      landing elsewhere. That class did not depend on the Pis at all before the
      redirect.

      2026-09-12, core4 powered down: **exactly 10 of 20** single-shot queries
      (`+tries=1`) dead-ended, so "roughly half" is the literal behaviour, not
      an approximation. With retries allowed, 20 of 20 answered and filtering
      still applied. The cost of losing one resolver is therefore latency
      rather than failure, for this class as well as the DHCP one.

      This is the argument for staggering automatic upgrades rather than
      enabling them fleet-wide on one schedule: the degradation is survivable
      for one resolver at a time and total if both windows overlap

### Phase 8: afterwards

One at a time, weeks apart, now that the house is boring.

- [ ] **Alert when a host boots the wrong system.** core5 fell back to its SD
      card on 2026-09-04 with a loose NVMe ribbon and ran a two-week-old
      generation for hours, looking healthy from every angle. Whatever the stack
      ends up being, it needs to compare each host's booted root device and
      running system generation against what the flake says it should be,
      because a host that is up, answering and wrong is invisible to liveness
      checks. See [recovery.md](recovery.md).
- [ ] **Decide the monitoring stack, then instrument gate.** Deliberately not
      "wire gate into pimon": pimon does host liveness, and the questions here
      are WAN state, conntrack pressure, per-interface throughput, DHCP pool
      exhaustion and DNS failure ratios, plus *alerting*, since a router fault
      you learn about by noticing the internet is broken is one monitoring did
      not catch.

      The conventional answer is Prometheus or VictoriaMetrics with Grafana on
      core5, scraping `node_exporter` fleet-wide plus exporters for AdGuard,
      UniFi and nftables. core5 is on NVMe as of 2026-08-31, which was the
      blocker: a TSDB writes harder and more continuously than even the UniFi
      database does, and that is not a workload for an SD card.

      Note this is also what would force gate to have an `ip` in `lib/net.nix`,
      since core5's firewall opens a port per `pimonAgents` entry and reads that
      attribute. Decide what the address would mean first.
- [ ] **Inbound remote access.** The one with clear payoff: SSH into the fleet,
      the AdGuard UI, Home Assistant, and filtered DNS from a hotel. Answer the
      CGNAT question above first, since it picks the technology.
- [ ] **IPv6**: DHCPv6-PD, a /64 per VLAN, `corerad` for advertisements, and an
      explicit v6 default-deny inbound. Genuinely unexplored: the Nest ran with
      v6 disabled, so whether the ISP delegates a prefix at all is unknown until
      gate asks for one. There is no NAT hiding anything on v6, so every device
      is globally routable and the forward chain is the only thing standing in
      front of the IoT VLAN. Disabling v6 on the WAN was a legitimate temporary
      choice through the cutover, but it should be revisited rather than
      forgotten.
- [ ] **Policy-based routing through a commercial VPN**, only if wanted.
      WireGuard on an N100 tops out well under line rate, so route one VLAN
      through it rather than everything, and add a kill switch so the tunnel
      dropping does not silently leak to WAN.

## What was built

Each phase had an exit test, and none started until the previous one passed.
Everything up to Phase 7 happened with gate sitting behind the Nest on a DHCP
lease, so nothing was load-bearing until the cutover.

**Phase 0, recon.** Cabled and powered 2026-08-30. Sockets ETH0-ETH3 map to
`enp2s0`-`enp5s0` in PCI order, from the chassis labels. IPv6 on the LAN turned
out to be nothing useful: only a ULA the Nest generated itself, because the Nest
had IPv6 disabled, so it said nothing about what the ISP offers. The recovery
USB was built and booted once, which is where the real find was: `sudo` did not
work on the box at all, because the pre-flake `configuration.nix` defined
`users.users.nick` with no password field. That would have blocked every
subsequent phase and was invisible until something needed root.

The Nest's WAN MAC was never recorded. It stopped mattering when the Nest left.

**Phase 1, addressing.** Four segments, the schema landing in `lib/net.nix`
without anything wired to it yet. `work` was added later, in #63, once the shape
had proven itself. See [network.md](network.md) for the reasoning that survived.

**Phase 2, the host.** gate's config merged and deployed. The first deploy had
to name the flake attribute explicitly, since the box's hostname was still
`router`, and used `boot` plus a reboot rather than `switch`, because it moved
the box off NetworkManager onto scripted networking over the live SSH session.
The console password was changed off the public `initialPassword` at the same
time.

**Phase 3, interface renames.** systemd `.link` files matched on PCI path, done
before a single firewall rule existed, which was the point of doing it then.

**Phase 4, routing behind the Nest.** nftables with `filterForward`, so the
forward chain defaults to drop; `networking.nat` for masquerade rather than a
hand-written ruleset, because a box becoming the house router is a poor place to
be original; Kea with a persistent lease file; conntrack raised off its desktop
default. SSH moved from a global `allowedTCPPorts = [ 22 ]` to per-interface
scoping named in `lib/net.nix`.

**Phase 5, DNS.** gate got its own recursive Unbound on loopback so it can be
rebuilt with the Pis down. 8.8.8.8 was dropped from `fallbackDns` on both Pis,
from the `bootstrapDns` default, and from core5's `networking.nameservers`,
which the original survey missed. Quad9 replaced it rather than nothing, so
redundancy survives and comes from a second operator rather than a second
address belonging to the first.

**Phase 6, VLANs and UniFi.** The largest phase, and the one that cost the most
hours. The controller went up on core5 in pinned containers; the Flex switch and
U7 Pro were adopted; VLAN interfaces and per-segment Kea subnets landed; the
switch uplink moved from the Nest to `lan0`; SSIDs were tagged per segment.

The switch adoption was expected to cycle PoE and hard-reset all three Pis, and
did not: provisioning alone does not require a reboot. **A firmware update
does**, and automatic device updates were turned off before adopting, so that
reboot is deferred rather than avoided.

Three things went wrong here and are worth keeping:

- Making every segment tagged looked tidier and stranded the switch for two
  hours. The untagged-native invariant in [network.md](network.md) is the
  result.
- The switch became unadoptable and needed a specific recovery order. That is
  now a runbook in [unifi.md](unifi.md).
- gate answered ARP for addresses belonging to other segments, so the AP renewed
  a lease from the wrong subnet indefinitely. `arp_ignore` and `arp_announce`
  in `hosts/gate/routing.nix` are the fix, and the comment there has the full
  account.

**Phase 7, cutover.** 2026-09-05. Power off the modem, move the WAN cable, power
the modem back on and wait for sync, confirm the lease, verify from a client,
unplug the Nest. The modem power-cycle is what clears its cached CPE MAC.

`"wan"` was deleted from `gate.sshInterfaces` as part of it, which is the
difference between a router and a router with sshd listening on the internet. It
was removed only after a replacement path was proven rather than assumed: SSH
from a trusted-segment address over `br-trusted`, verified before the line
changed and not after.

The fleet renumber was already done, on 2026-09-02, ahead of this phase, so the
cutover was the cable move and that one edit.

## Hardware notes

**i226-V link flapping.** ASPM-related drops are common on these NICs. If links
flap intermittently, `pcie_aspm=off` as a kernel parameter is the usual fix.
Early steppings also had firmware bugs. `ethtool` and `pciutils` are installed
on gate for exactly this.

**Thermals.** Fanless CWWK chassis run warm. Worth a look at `sensors` under
sustained load.

## The lesson that generalises

**An address on the wrong wire fails silently, and in one direction.** Through
the Phase 6 cutover each Pi held its flat-LAN address alongside its segment
address, which is what kept it reachable while the switch uplink moved. Once
`end0` was carrying the servers VLAN, the flat address was unreachable from
everywhere, but it kept its directly-connected route: core5 answered nothing on
`192.168.86.49` and *also* sent everything bound for `192.168.86.0/24` onto the
servers VLAN rather than via gate. The visible symptom was the controller
reporting the switch unreachable while gate could ping that same switch fine.

Dual addressing is the right tool during a cutover and a liability the moment it
finishes. Retire the old address in the same session that completes the move.
