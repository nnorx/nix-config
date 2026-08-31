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
| WAN protocol: DHCP or PPPoE? | Almost certainly DHCP: cable handoffs are, and PPPoE would have meant typing credentials into the Home app at setup. Its Internet screen shows which. Worst case is discovering it at cutover and rescheduling, with the Nest plugged back in |
| Does the WAN need 802.1Q VLAN tagging? (AT&T fiber does) | **No.** Nest Wifi has no 802.1Q option on its WAN and the house works, so there is nothing to tag |
| Does the ISP bind the lease to a MAC? | A cable modem caches the CPE MAC for the lease. Power-cycling the modem clears it, which is why Phase 7 starts there |
| Behind CGNAT? | **Open, and deliberately deferred to Phase 8.** It changes WireGuard vs Tailscale and nothing before that, and once gate is the router it reads its own WAN address for free. A TTL-limited ping from inside the LAN proves nothing either way: the Nest's next hop is 172.20.25.131, and ISPs number internal router interfaces out of RFC1918 routinely. The Home app's Internet screen answers it early if convenient |
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

- [x] Check what IPv6 reaches the LAN. Done 2026-08-30, and the answer is
      nothing useful: gate holds only a `fd00::/8` ULA that the Nest generated
      itself, because **the Nest has IPv6 disabled**. So this says nothing
      about whether the ISP offers v6.

      Turning it on at the Nest was considered and skipped. It would test the
      Nest's v6 implementation, not gate's, and the thing that matters is
      whether *gate* can get a DHCPv6-PD prefix delegation, which only Phase 8
      can answer. Leaving it off is also the state Phase 7 wants: the plan
      already treats v6-off-on-WAN as a legitimate temporary choice through
      cutover

      There is no standalone modem test. An earlier draft had one, on the
      reasoning that guessing the WAN shape and finding out at cutover is
      expensive. It is not, here: VLAN tagging is already ruled out by the Nest
      working at all, PPPoE is visible in the Home app and its worst case is a
      rescheduled evening with the Nest plugged back in, and CGNAT is a Phase 8
      input that gate answers by itself once it is routing. None of that is
      worth taking the house offline for

- [ ] Answer the rest of the Open Questions table
- [x] Build the recovery USB and boot it once, per the README. Done
      2026-08-30, and it took the firmware visit the test was designed to
      decide. Findings worth keeping:

      The image and the reader were never the problem. `lsblk` showed the
      hybrid layout written correctly, and `efibootmgr -v` already listed the
      reader as a boot entry. It simply sat third in `BootOrder`, behind two
      entries on the internal ESP. The firmware timeout was also 1 second,
      which is not catchable.

      **`sudo` did not work on the box, and that was the real blocker.** The
      pre-flake `/etc/nixos/configuration.nix` defines `users.users.nick` with
      no password field, so the account had none and no `sudo` could succeed.
      That blocks `nixos-rebuild` too, so it blocked all of Phase 2 and was
      invisible until something needed root. Fixed from the live environment
      with `nixos-enter` and `passwd`.

      USB now precedes the internal disk in the boot order, which makes
      recovery headless from here on: plug the stick in, reboot over SSH, and
      it comes up in the live environment with no firmware interaction. The
      cost of that is a live SD card left inserted boots the rescue image on
      every reboot, which during Phases 3 and 4 is indistinguishable from a
      broken deploy. **Store the card with the box, not in it.**

- [ ] Know what the boot menu is for, whether or not you ever see it: every
      `nixos-rebuild` leaves a generation, systemd-boot lists the previous
      ones, and selecting one is how a deploy that breaks networking gets
      undone. Phases 3 and 4 are exactly that risk. `configurationLimit = 10`
      in `hosts/gate` keeps ten of them on the ESP
- [ ] Note the Nest's WAN MAC before anything is unplugged

**Exit test:** the box is recoverable without the network, and the only
remaining WAN unknown is one whose worst case is plugging the Nest back in and
picking another evening.

## Phase 1: design the addressing, then encode it

Output is a merged `lib/net.nix`. No hardware changes.

- [x] Write the segment table: id, name, subnet, gateway, DHCP pool range
- [x] Decide port allocation across the four NICs
- [x] Extend `lib/net.nix` with the schema, without wiring anything to it
- [ ] Static reservations for the switch and the AP. Deferred to Phase 6 on
      purpose: reservations are keyed on MAC addresses, which do not go in this
      repo, so they arrive with the private input. The Pis need none, since
      they take static addresses from their own NixOS config

Four segments, third octet carrying the VLAN id so an address names its own
segment. `gate` holds `.1` in each. Below `.100` is reserved for statics and
reservations, `.100-.240` is the dynamic pool.

192.168 rather than 10.x for a concrete reason. Cloudflare WARP, on the work
profile, routes `10.8.0.0/13` into its tunnel, and that range swallows
`10.10.0.0/16`. Numbering the house there would have made every device at home
unreachable from the work laptop whenever WARP connected, and since the profile
is employer-managed it could not have been excluded locally. Checked with
`route -n get 10.10.10.1`, which came back on `utun4`. Corporate profiles
rarely claim 192.168 space, because that is where employees' home networks
live.

| VLAN | Segment | Subnet | Holds | Policy |
|---|---|---|---|---|
| 10 | trusted | 192.168.10.0/24 | Laptops, phones, the wired workstation | Full access |
| 20 | servers | 192.168.20.0/24 | core4, core5, lifeline, switch, AP | Reachable from trusted |
| 30 | iot | 192.168.30.0/24 | Cameras, plugs, TVs | WAN only, no LAN |
| 40 | guest | 192.168.40.0/24 | Visitors | Internet only, client isolation |

No separate mgmt segment: with three managed devices it is more ceremony than
isolation, so the switch, AP and `gate` sit on servers.

`servers` is the one that is not optional. The port-53 redirect that catches
hardcoded resolvers only preserves the client's source address when the
resolver is on a different subnet, which is the whole reason the Pis are not
simply on trusted.

Port roles:

| Port | Socket | Role |
|---|---|---|
| `wan` | ETH0 | The modem |
| `lan0` | ETH1 | Tagged trunk to the Flex switch, every segment on it |
| `lan1` | ETH2 | Untagged, bridged into trusted: a dedicated 2.5G run |
| `lan2` | ETH3 | Spare, left down |

`lan1` is bridged into trusted rather than given a subnet of its own, so the
wired machine shares a broadcast domain with the phones and laptops. Put it on
its own subnet and mDNS stops working between them, which breaks printer and
cast discovery in a way that is annoying to diagnose later.

Renumbering stays a one-file change. The schema lives in `lib/net.nix` and
consumers reference attribute names rather than values, so the cutover is
editing `hosts.*.ip` here and retiring the `lan` block.

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
- [ ] `system.autoUpgrade` is already `enable = false` fleet-wide in
      `modules/baseline.nix`, so the unattended-3am-reboot problem is already
      handled. Confirm it stays that way for `gate` specifically

`allowedTCPPorts = [ 22 ]` in `modules/firewall.nix` is fleet-wide and
unscoped, which on `gate` means port 22 is open on the interface that will face
the internet. It was listed here originally and that was wrong: `wan` **is**
the management path until `lan0` exists, so scoping SSH off it locks everyone
out, and scoping it to `wan` protects nothing. It moves with the management
path, in Phase 4.

**Exit test:** `gate` rebuilds cleanly, SSH still works, and `ss -tlnp` shows
`sshd` bound where expected.

## Phase 3: rename the interfaces

Small phase, gates everything after it. No firewall rules exist yet.

- [ ] systemd `.link` files renaming each NIC to `wan`, `lan0`, `lan1`,
      `lan2`, matched on **PCI path rather than MAC address**. That defends
      against what actually reorders interfaces, which is systemd's
      predictable-naming scheme changing between releases, while keeping
      hardware identifiers out of a public repo. The risk it does not cover is
      firmware renumbering the PCI buses, which fixed hardware does not do and
      which the MAC check below catches anyway
- [ ] Update `lib/net.nix` so `gate.wanIface` is `wan`. Note which attribute
      that is: `iface` is the NIC `hosts/common` binds a static address and the
      default gateway to, so on this host it names a LAN port and arrives in
      Phase 4 with the address, not here
- [ ] Deploy behind `deploy-guard`, since a rename that goes wrong leaves no
      way in:
      ```
      sudo deploy-guard arm 15
      nrb && sudo reboot
      sudo deploy-guard confirm
      ```
- [ ] Verify the rename landed on the right hardware: `ip -br link` should show
      `wan` carrying the MAC recorded for ETH0 outside this repo. This is the
      one check that catches a PCI-path mismatch, and it is worth doing by eye
      rather than trusting that four sequential paths stayed sequential

`wan` and `lan0` are safe names because the kernel never auto-generates them, so
there is no rename collision.

**Exit test:** `ip -br link` shows the same names across two reboots, and the
port called `wan` is physically the port intended.

## Phase 4: routing, still behind the Nest

`gate`'s WAN keeps its lease from the Nest. Double NAT breaks inbound, UPnP and
some games, none of which is being tested here.

- [x] Raise `net.netfilter.nf_conntrack_max` off its desktop default; keep
      `checkReversePath` on. IPv4 forwarding comes from the nat module, not by
      hand
- [x] Static address on `lan0`: `192.168.10.1`, the trusted gateway. Set on the
      interface directly rather than through `hosts/common`, which is for
      hosts with a single address on a flat LAN
- [x] nftables backend with `filterForward`, so the forward chain defaults to
      drop, and `networking.nat` for masquerade. The nat module emits the
      internal-to-external forward rule itself, so there is nothing to write by
      hand
- [x] Kea on `lan0`, handing out the trusted pool, both Pi resolvers, and a
      persistent lease file
- [ ] Cable `lan0` **directly to one test client**, not to the Flex switch.
      `wan` is plugged into that switch, because the switch is currently just
      an extension of the Nest's LAN and that is how gate reaches the Nest.
      Putting `lan0` on the same switch would leave gate's WAN and LAN sides
      sharing one L2 segment, which does not route. The switch only moves
      behind `lan0` once the Pis move with it, which is Phase 6
- [ ] Move management onto `lan0`, then scope SSH to it in
      `modules/firewall.nix` and bind `sshd` to LAN addresses rather than
      relying on firewall rules alone. This is the first point at which that is
      possible: until `lan0` carries the session, `wan` is the way in

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
- [ ] Move the Flex switch's uplink from the Nest to `lan0` and trunk the VLANs
      to it, tag SSIDs on the AP. This is where the Pis renumber into
      `servers`, so it is also where house DNS starts depending on gate
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
      Start by answering the CGNAT question deferred from Phase 0, which is now
      a one-liner: read gate's own WAN address off `wan`. Routable means
      WireGuard, and 100.64.0.0/10 means Tailscale
- [ ] IPv6: DHCPv6-PD, a /64 per VLAN, `corerad` for advertisements, and an
      explicit v6 default-deny inbound. Genuinely unexplored: the Nest ran with
      v6 disabled, so whether the ISP delegates a prefix at all is unknown
      until gate asks for one. There is no NAT hiding anything on v6,
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
