# Router build plan (gate)

`gate` is a CWWK N100 with four Intel i226 NICs, destined to replace the Google
Nest as the house router. The goals, in order: multi-gig routing on the LAN
side, getting Google out of the network path, and remote access into the fleet.

Every phase up to the cutover happens with `gate` sitting *behind* the Nest on a
DHCP lease, so nothing here is load-bearing until Phase 7. Each phase has an
exit test. Do not start the next one until the current one passes.

A note on scope: the N100 box is a wired router and firewall. It has no Wi-Fi.
The U7 Pro is what replaces the Nest's radios, and the two jobs are separate.

## Open questions

Phase 0 fills these in. Several later phases cannot be designed without them.

| Question | Answer |
|---|---|
| ISP handoff: pure modem/ONT, or a gateway needing bridge mode? | **Standalone modem, no router in it.** Nothing to bridge |
| WAN protocol: DHCP or PPPoE? | Expected DHCP. **Confirm in Phase 0 with a laptop on the modem**, not at cutover |
| Does the WAN need 802.1Q VLAN tagging? (AT&T fiber does) | Not expected on a cable handoff. Same test, same phase |
| Does the ISP bind the lease to a MAC? | A cable modem caches the CPE MAC for the lease. Power-cycling the modem clears it, which is why Phase 7 starts there |
| Behind CGNAT? | **Open**, and answered by the modem test below rather than from inside the LAN. A TTL-limited ping put the Nest's next hop at 172.20.25.131, which proves nothing either way: ISPs number internal router interfaces out of RFC1918 routinely, and it is not 100.64.0.0/10. What settles it is the address the CPE holds on its own WAN |
| Service tier actually purchased | |
| NIC MAC addresses | Recorded outside this repo, see "What stays out of this repo" |
| Which physical port is which kernel name | `enp2s0`=ETH0, `enp3s0`=ETH1, `enp4s0`=ETH2, `enp5s0`=ETH3, matching PCI order. All four are identical i226, so `wanIface` stays ETH0 |

CGNAT is the one that changes a design decision rather than a config value: if
the WAN address is in 100.64.0.0/10, inbound WireGuard is off the table and
Phase 8 becomes Tailscale.

## Decisions already made

**DNS stays on the Pis.** `gate` does not take over resolving for the house.
Three reasons: the router will be rebooting constantly during buildout, and
house-wide DNS outages generate more complaints than actual outages do; core4
and lifeline are already two independent paths that share no state, which beats
one resolver on the box that is also the single point of failure for everything
else; and it matches how the rest of the config is split.

**`gate` gets its own resolver path, independent of the Pis.** If
`/etc/resolv.conf` points at the Pis and the Pis are down, `nixos-rebuild`
cannot resolve `github.com`, so the router cannot be fixed by rebuilding it.
This bootstrap loop is the reason the item exists.

**Clients get both Pi addresses directly via DHCP option 6**, rather than the
router proxying DNS to them the way the Nest does today. Proxying costs
per-client attribution: every query arrives from the gateway address, so
per-client stats, per-client rules and per-client rate limits all stop working.
That is most of the reason to run AdGuard rather than a plain blocklist. The
comments in `modules/adguardhome.nix` about ratelimits being a whole-LAN ceiling
are written against the proxying design and become wrong at this point.

**The Pis move to their own VLAN, separate from clients.** This is not tidiness,
it is what makes the port-53 DNAT redirect work. Redirecting a client's query to
a resolver on the *same* subnet means the reply comes back from the Pi's address
rather than the address the client sent to, and the client drops it as
unsolicited. Fixing that needs a masqueraded hairpin, which destroys the source
IP the redirect was meant to preserve. Across subnets there is no hairpin, so
the client IP survives and AdGuard attribution holds.

**Rename the interfaces before writing a single firewall rule.** `igc`
enumeration order can shift across a kernel or firmware update. Rules that name
`wan` stay correct; rules that name `enp2s0` are correct only until they are
not, and a silent WAN/LAN swap under a permissive ruleset is the failure that is
hard to walk back.

**Drop 8.8.8.8.** It is in `fallbackDns` on both Pi hosts and in the
`bootstrapDns` default in `modules/adguardhome.nix`. Unbound is recursive so
fallbacks rarely fire, but "get Google out of the path" is a stated goal and
this is a one-line fix.

## What stays out of this repo

This repo is public and worth keeping that way. The module logic, the firewall
rules and the reasoning behind the topology are the useful part, and a ruleset
that is only correct while nobody has read it was never correct. Three kinds of
thing do not belong here.

**Secrets, which sops handles.** WireGuard private keys, DDNS API tokens, both
AdGuard admin hashes (#32: core4's and lifeline's), any PSK. `sops-nix` renders these at activation, so
the Nix store holds ciphertext or a sentinel rather than the value.

**Identifying data, which is not secret but is a map to one specific house.**
The WAN address, the DDNS hostname, SSIDs (wigle.net maps SSIDs to physical
locations), NIC MAC addresses, and above all the Kea reservation table, which is
an inventory of every device in the house paired with a vendor OUI. None of it
is cryptographically sensitive. All of it turns "a well-built router config"
into "Nick's house, and what is in it."

`lib/net.nix` already anticipates this. Its header notes that consumers
reference attribute names rather than values, "which keeps the option open of
moving this file into a private flake input later without editing anything that
reads it." Phase 1 is when that option gets exercised, because Phase 1 is when
reservations arrive. RFC1918 addresses alone are fine in public; a per-device
MAC table is not.

**Anything the UniFi controller exports.** Backups carry Wi-Fi PSKs and device
credentials. They stay off the repo entirely, encrypted or not.

Two things are already public and should be treated as disclosed rather than
merely fixed: the bcrypt hashes in `hosts/core4` and `hosts/lifeline`. core4's
is cost 05, cheap enough to attack offline that it wants rotating rather than
just encrypting; lifeline's is cost 10 but has been in a public repo just as
long. #32 covers both. So is `initialPassword = "changeme"` in `hosts/common`,
which is every host's console and sudo password until someone runs `passwd`.

## Phase 0: recon, no config changes

- [x] Cable `gate` and power it on. Done 2026-08-30: it holds a Nest lease at
      192.168.86.126, and only `enp2s0` has carrier
- [x] Record the four NIC MACs, kept outside this repo. Phase 3 renames by MAC,
      and losing them means another trip to the rack
- [x] Map the sockets to kernel names. Answered 2026-08-30 from the chassis
      labels: ETH0 through ETH3 are enp2s0 through enp5s0, in PCI order.
      Confirm the cabled socket is ETH0, which closes it end to end, since
      enp2s0 is the interface holding carrier

      Had the labels not existed, the walk would have been: leave the existing
      cable in enp2s0 so the session survives, put a spare cable from the free
      switch port into each other socket in turn, and read `ip -br link` for the
      name that flips from NO-CARRIER to LOWER_UP. It has to happen before the
      first deploy either way: afterwards `hosts/common` sets
      `useDHCP = false` with only `wanIface` opted back in, so a cable in any
      other port gets no address and the way back is the console

- [ ] The modem test, which closes four open questions at once: CGNAT, DHCP vs
      PPPoE, VLAN tagging, and what IPv6 the ISP offers. Guessing any of them
      and finding out at Phase 7 means discovering it with the house offline.

      Use gate rather than a laptop. It is the box that does this for real at
      cutover, so the NIC and the DHCP client under test are the ones that will
      be doing the job. ETH0 stays on the LAN throughout, so the SSH session
      survives and only internet access drops. Do it **before deploying**,
      while NetworkManager still manages all four NICs and will lease on ETH1
      without config.

      1. Unplug the modem's cable, then **power-cycle the modem** and wait for
         steady lights. A cable modem binds its lease to the first CPE MAC it
         sees and is still holding the Nest's, so skipping this is the usual
         reason the test appears to fail
      2. Cable the modem to gate's **ETH1** (enp3s0)
      3. `ip -br addr show enp3s0`, `ip -6 addr show enp3s0`, `ip route`,
         `curl --interface enp3s0 -s https://ifconfig.me`, and
         `journalctl -u NetworkManager -n 30`
      4. Unplug, **power-cycle the modem again**, reconnect the Nest. It will
         not get a lease while the modem holds one bound to gate's MAC

      Reading it: enp3s0's address matching what ifconfig.me returns means a
      bridged modem, a public address, and WireGuard is viable. A private
      address on enp3s0 with a different public one means CGNAT, and Phase 8
      becomes Tailscale. An address arriving at all rules out PPPoE and VLAN
      tagging together
- [ ] Answer the rest of the Open Questions table
- [ ] Boot `gate` with a monitor and keyboard, confirm the systemd-boot menu is
      reachable and an older generation can be selected
- [ ] Build a NixOS recovery USB and boot it once to confirm it works
- [ ] Note the Nest's WAN MAC before anything is unplugged

**Exit test:** "what happens when the WAN cable moves" is answerable without
guessing, and the box is recoverable without the network.

## Phase 1: design the addressing, then encode it

Output is a merged `lib/net.nix`. No hardware changes.

- [ ] Write the VLAN table: id, name, subnet, gateway, DHCP pool range
- [ ] Assign static reservations for the Pis, the switch, the AP, and `gate`
- [ ] Decide port allocation across the four NICs: which is WAN, which is the
      trunk to the Flex switch, whether one gets a dedicated run
- [ ] Extend `lib/net.nix` with the VLAN schema, without wiring anything to it

A starting point for the VLAN split:

| VLAN | Purpose | Policy |
|---|---|---|
| mgmt | `gate`, switch, AP | No inbound from anywhere else |
| trusted | Laptops, phones | Full access |
| servers | core4, core5, lifeline | Reachable from trusted; makes the DNS redirect work |
| iot | Cameras, plugs, TVs | No LAN access, WAN only |
| guest | Visitors | Internet only, client isolation on |

Renumbering the LAN is currently a one-file change. Preserve that: the VLAN
schema belongs in `lib/net.nix`, and consumers should keep referencing attribute
names rather than values.

**Exit test:** `nix flake check` passes and rebuilding a Pi is a no-op diff.

## Phase 2: land the host PR and close the firewall gap

- [ ] Merge the `gate` host PR (#8). It no longer stacks on the sops PR: the
      `hosts/common` split it carried landed independently in #12. It is not
      gate-only, though: it makes `system.stateVersion` and `home.stateVersion`
      overridable per host, which every host evaluates, and it edits
      `lib/net.nix`, which every host reads. Re-verify the Pis still read 25.11
- [x] Confirm the UUIDs in `hosts/gate/hardware-configuration.nix` still match
      `lsblk -f` on the box. Verified 2026-08-30: root and ESP both match, and
      the firmware is UEFI as the config assumes
- [ ] Deploy naming the attribute explicitly: `#gate`. The box's own hostname
      is currently `router`, and `nixos-rebuild` resolves the flake attribute
      from the hostname when `#name` is omitted, so a bare invocation looks for
      a `router` config that does not exist. The `nrs`/`nrb` aliases omit it on
      purpose and are only correct from the second deploy onward
- [ ] Deploy it with `boot` plus a reboot, not `switch`. It moves the box off
      NetworkManager onto scripted networking, on the interface the session is
      running over. Have console access at the box for this one: the current
      `nick` account loses SSH entirely, since `modules/ssh.nix` sets
      `AllowUsers = [ hostname ]`, turns password auth off, and deploys the key
      to `gate` alone. Update `~/.ssh/config` to `User gate` afterwards; it is
      the same key, so nothing else changes
- [ ] Change gate's password at the console. `hosts/common` creates the account
      with `initialPassword = "changeme"`, which is public in this repo and, with
      `wheelNeedsPassword = true` in the baseline, is also the sudo password.
      The README says this for a freshly flashed Pi and it applies here too
- [ ] Make SSH interface-scoped in `modules/firewall.nix`, and bind `sshd` to
      LAN addresses explicitly rather than relying on firewall rules alone
- [ ] `system.autoUpgrade` is already `enable = false` fleet-wide in
      `modules/baseline.nix`, so the unattended-3am-reboot problem is already
      handled. Confirm it stays that way for `gate` specifically

`allowedTCPPorts = [ 22 ]` in `modules/firewall.nix` is fleet-wide and
unscoped. That is correct for a Pi on a trusted LAN. On `gate` it means port 22
is open on the internet-facing interface the moment the WAN cable moves. The
per-interface idiom already exists in `hosts/core4/default.nix`, so this is a
change in shape rather than a new mechanism.

**Exit test:** `gate` rebuilds cleanly, SSH still works, and `ss -tlnp` shows
`sshd` bound where expected.

## Phase 3: rename the interfaces

Small phase, gates everything after it. No firewall rules exist yet.

- [ ] systemd `.link` files matching each NIC by MAC, renaming to `wan`,
      `lan0`, `lan1`, `lan2`
- [ ] Update `lib/net.nix` so `gate.wanIface` is `wan`. Note which attribute
      that is: `iface` is the NIC `hosts/common` binds a static address and the
      default gateway to, so on this host it names a LAN port and arrives in
      Phase 4 with the address, not here
- [ ] Deploy with `nrb`, reboot, verify, reboot again

`wan` and `lan0` are safe names because the kernel never auto-generates them, so
there is no rename collision.

**Exit test:** `ip -br link` shows the same names across two reboots, and the
port called `wan` is physically the port intended.

## Phase 4: routing, still behind the Nest

`gate`'s WAN keeps its lease from the Nest. Double NAT breaks inbound, UPnP and
some games, none of which is being tested here.

- [ ] IPv4 forwarding sysctls; keep `networking.firewall.checkReversePath`
      strict; raise `net.netfilter.nf_conntrack_max` off its desktop default
- [ ] Static address on `lan0` from `lib/net.nix`: give gate an `ip` and an
      `iface` of `lan0`, which is what makes `hosts/common` configure it
- [ ] nftables: default-drop forward, allow lan to wan with established/related
      return, masquerade on `wan`
- [ ] Kea on the LAN side, with the static reservations from Phase 1
- [ ] Plug the Flex switch into `lan0`, move one non-critical client onto it

Iterate with `nixos-rebuild test` plus a detached rollback timer, so a bad
ruleset self-heals in a few minutes instead of a trip to the rack.

**Exit test:** the test client gets a lease, reaches the internet, and cannot
reach anything on `gate` it should not.

## Phase 5: wire in DNS

- [ ] Kea hands out both Pi addresses as DNS servers
- [ ] `gate` resolves through a path that does not depend on the Pis
- [ ] Drop 8.8.8.8 from `fallbackDns` on core4 and lifeline, and from the
      `bootstrapDns` default in `modules/adguardhome.nix`
- [ ] Confirm AdGuard is logging real client IPs rather than the gateway
- [ ] Revisit the ratelimit comments in `modules/adguardhome.nix`, which assume
      the proxying design
- [ ] Update the DNS flow paragraph in `README.md`, which currently describes
      the router proxying client DNS

**Exit test:** pull power on one Pi and the test client still resolves. Then run
`nixos-rebuild` on `gate` with both Pis down and it still reaches GitHub.

## Phase 6: VLANs and UniFi

The largest phase. Split it across sessions.

- [ ] Stand up the UniFi controller on core5 (Docker is the low-friction path;
      `services.unifi` exists in nixpkgs, but check MongoDB on aarch64 first)
- [ ] Turn off remote access and cloud in the controller, or Google's telemetry
      has just been swapped for Ubiquiti's
- [ ] Adopt the Flex switch and the U7 Pro
- [ ] VLAN interfaces on `gate`, one Kea subnet per VLAN
- [ ] Trunk the VLANs to the switch, tag SSIDs on the AP
- [ ] Inter-VLAN policy: iot isolated, guest internet-only, trusted reaches
      servers
- [ ] Port-53 DNAT redirect for hardcoded resolvers, which works now that
      clients and Pis are on separate subnets
- [ ] Document the controller backup procedure in `README.md`

The controller database is state that lives outside the flake and is not
reproducible from Nix. Treat backing it up as a documented manual step.

**Exit test:** a device on iot cannot ping anything on trusted, and a client
with DNS hardcoded to 8.8.8.8 still shows up in AdGuard's logs.

## Phase 7: cutover

A weeknight, not a Friday.

Pre-flight:

- [ ] Console and keyboard physically at the box
- [ ] Recovery USB present
- [ ] Known-good generation identified in the boot menu
- [ ] Nest kept and not factory-reset, so reverting is possible

Sequence: power off the modem, move the WAN cable, power the modem back on and
wait for sync, confirm `gate` gets a WAN lease, verify from one client, then
unplug the Nest. The modem power-cycle is what clears its cached MAC lease.

**Exit test:** an external port scan of the WAN address shows nothing listening,
and a full reboot of `gate` brings the house back with no manual steps.

## Phase 8: afterwards

One at a time, weeks apart, once the house is boring.

- [ ] `node_exporter` or a pimon agent on `gate`, reporting to core5
- [ ] Inbound remote access. This is the one with clear payoff: SSH into the
      fleet, the AdGuard UI, Home Assistant, and filtered DNS from a hotel.
      WireGuard if there is a routable WAN address, Tailscale if behind CGNAT
- [ ] IPv6: DHCPv6-PD, a /64 per VLAN, `corerad` for advertisements, and an
      explicit v6 default-deny inbound. There is no NAT hiding anything on v6,
      so every device is globally routable and the forward chain is the only
      thing standing in front of the IoT VLAN
- [ ] Policy-based routing through a commercial VPN, only if wanted. WireGuard
      on an N100 tops out well under line rate, so route one VLAN through it
      rather than everything, and add a kill switch so the tunnel dropping does
      not silently leak to WAN

Disabling IPv6 on the WAN entirely is a legitimate temporary choice through
Phase 7, but it should be revisited rather than forgotten.

## Validation checklist

Run these once the house is on `gate`:

- [ ] `iperf3` between two clients on different VLANs, forwarded through `gate`,
      confirming the routing path does multi-gig rather than just the links
      negotiating at 2.5G
- [ ] WAN speed test matching the service tier
- [ ] External port scan of the WAN address showing nothing listening
- [ ] `dnssec-failed.org` fails to resolve, proving DNSSEC validation is live
- [ ] A DNS leak test showing the fleet's resolver, not the ISP's
- [ ] One Pi powered off, house still resolves
- [ ] `gate` rebooted, everything returns with no manual intervention,
      including Kea leases and the WAN lease
- [ ] iot cannot reach trusted; guest cannot reach anything

## Known gotchas

**i226-V link flapping.** ASPM-related drops are common on these NICs. If links
flap intermittently, `pcie_aspm=off` as a kernel parameter is the usual fix.
Early steppings also had firmware bugs.

**Thermals.** Fanless CWWK chassis run warm. Watch `sensors` for the first week
under sustained load.

**DoH is advisory, not enforceable.** Port 853 and known DoH endpoint IPs can be
blocked, but browsers ship encrypted DNS over 443 and the endpoint lists change.
Browser policy is more reliable than firewall rules here.

**Local name resolution.** Kea does not register hostnames with AdGuard. Static
reservations in `lib/net.nix` plus AdGuard rewrites for the handful of names
worth having is the simplest answer, and keeps the topology in one file.

**UniFi config is not in the flake.** Backups are a manual, scheduled step.
