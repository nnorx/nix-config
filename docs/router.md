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

**Drop 8.8.8.8.** Done. It was in `fallbackDns` on both Pi hosts, in the
`bootstrapDns` default in `modules/adguardhome.nix`, and in core5's
`networking.nameservers`, which the original survey missed. Replaced with Quad9
rather than simply removed, so redundancy survives and it comes from a second
operator rather than a second address belonging to the first.

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

servers has no pool. Everything on it is statically addressed: the Pis from
their own NixOS config, the switch and the AP from the UniFi controller.
Infrastructure that does not depend on DHCP being up is a better property for
the devices the rest of the network is reached through, and it is also what
keeps Kea off the trunk parent, since servers is the untagged VLAN there and a
raw socket on a trunk parent receives tagged frames too.

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
| 20 | servers | 192.168.20.0/24 | core4, core5, lifeline, switch, AP | Reachable from trusted. **No DHCP pool**: statically addressed |
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
- [x] Static address on `lan0`. Was `192.168.10.1` when it served trusted
      untagged; `lan0` is now the trunk and carries `192.168.20.1`, the servers
      gateway, with trusted moved to `br-trusted`. Set on the interface
      directly rather than through `hosts/common`, which is for hosts with a
      single address on a flat LAN
- [x] nftables backend with `filterForward`, so the forward chain defaults to
      drop, and `networking.nat` for masquerade. The nat module emits the
      internal-to-external forward rules itself from `internalInterfaces`, so
      those are never written by hand. Segment-to-segment rules are a separate
      matter and are written by hand, since nat says nothing about them
- [x] Kea, handing out one pool per segment, resolvers, and a persistent lease
      file. Retries opening its socket and requires every
      configured interface, so it cannot end up running deaf: by default it
      tries once and, on failure, stays up with no listener, which on a router
      means the house breaks an hour later when leases start renewing
- [ ] Cable `lan0` **directly to one test client**, not to the Flex switch.
      `wan` is plugged into that switch, because the switch is currently just
      an extension of the Nest's LAN and that is how gate reaches the Nest.
      Putting `lan0` on the same switch would leave gate's WAN and LAN sides
      sharing one L2 segment, which does not route. The switch only moves
      behind `lan0` once the Pis move with it, which is Phase 6
- [x] Scope SSH per interface. `modules/firewall.nix` no longer opens 22
      globally; each host names its SSH-reachable interfaces in `lib/net.nix`,
      and `services.openssh.openFirewall` is off so it cannot re-add the global
      rule behind that. gate lists `wan` and `lan0`, since `wan` is still the
      management path and faces the Nest's LAN rather than the internet.

      `sshd` is deliberately not given a `ListenAddress`. gate's WAN address
      comes from DHCP, so pinning the daemon to it makes its start depend on a
      lease, which trades a firewall problem for a boot-ordering one

Iterate with `nixos-rebuild test` plus a detached rollback timer, so a bad
ruleset self-heals in a few minutes instead of a trip to the rack.

**Exit test:** the test client gets a lease, reaches the internet, and cannot
reach anything on `gate` it should not. Then reboot `gate` behind the guard and
confirm all of it returns with no manual steps, which is the part that
distinguishes a working config from one that happened to be started by hand.

## Phase 5: wire in DNS

- [ ] Kea hands out both Pi addresses as DNS servers
- [x] `gate` resolves through a path that does not depend on the Pis: its own
      Unbound on loopback:53, recursing from the root servers
- [x] Drop 8.8.8.8 from `fallbackDns` on core4 and lifeline, from the
      `bootstrapDns` default in `modules/adguardhome.nix`, and from core5's
      `networking.nameservers`
- [ ] Confirm AdGuard is logging real client IPs rather than the gateway
- [ ] Revisit the ratelimit comments in `modules/adguardhome.nix`, which assume
      the proxying design
- [ ] Update the DNS flow paragraph in `README.md`, which currently describes
      the router proxying client DNS

**Exit test:** pull power on one Pi and the test client still resolves. Then run
`nixos-rebuild` on `gate` with both Pis down and it still reaches GitHub.

## Phase 6: VLANs and UniFi

The largest phase. Split it across sessions, and note the steps are not
equally disruptive:

| Step | Disruption |
|---|---|
| Controller on core5 | None |
| Adopt the U7 Pro | None, nothing depends on it yet |
| VLAN interfaces and Kea subnets on gate | None until a trunk exists |
| **Adopt the Flex switch** | **PoE cycles, all three Pis hard-reset** |
| **Move the switch uplink to `lan0`** | **Pis renumber, house DNS starts depending on gate** |
| SSIDs, inter-VLAN policy, DNS redirect | Moderate |

The switch adoption is the one that surprises: that switch supplies PoE to
every Pi, so provisioning it drops power to the whole DNS layer.

- [x] Stand up the UniFi controller on core5. Containers, pinned by digest.
      `services.unifi` was checked and rejected on evidence rather than taste:
      `unifi` and `mongodb` are both unfree, so neither is in
      `cache.nixos.org`, which would mean a Pi compiling MongoDB from source,
      CI attempting the same inside its 350-minute cap, and pushing the result
      to a public Cachix. See the README section for the rest
- [x] Turn off remote access and cloud in the controller, or Google's telemetry
      has just been swapped for Ubiquiti's. Not expressible in Nix: it lives in
      the controller's own database. Remote Management and Analytics off, and
      the admin is local: the `admin` record carries no `ubic_account_id`
- [x] Adopt the Flex switch and the U7 Pro. Both `adopted: true`.

      The switch adoption was expected to cycle PoE and hard-reset all three
      Pis, and did not: every uptime went up rather than resetting, and the
      controller never restarted. Provisioning alone does not require a reboot.
      **A firmware update does**, and automatic device updates were turned off
      before adopting, so that reboot is deferred rather than avoided. The
      switch is on 2.1.8.971. Update it deliberately, on its own evening, with
      the Nest pointed at a public resolver first, because that is the event
      that takes PoE away from the entire DNS layer
- [ ] Point the Nest at `1.1.1.1`/`9.9.9.9` before anything that can interrupt
      the Pis, and revert immediately afterwards. The Nest proxies rather than
      handing resolvers to clients, so it takes effect instantly both ways with
      no lease renewal. The failure mode of forgetting is silent: the house
      keeps working perfectly while AdGuard quietly stops filtering and stops
      seeing queries
- [x] VLAN interfaces on `gate`, one Kea subnet per VLAN, each subnet pinned to
      its interface so a request on one VLAN cannot be answered from another's
      pool. `servers` is untagged on the trunk, because the switch and AP have
      to reach the controller to be managed at all, and carries no DHCP at all,
      because a raw socket on a trunk parent also receives tagged frames
- [ ] Move the Flex switch's uplink from the Nest to `lan0`. This is where the
      Pis land on `servers` and where house DNS starts depending on gate.

      The problem this has to solve: the moment the uplink moves, a Pi still
      configured only for the flat LAN is on a segment where that address does
      not route, unreachable, and so unfixable. The fix is to give each Pi its
      segment address *in advance*, alongside the flat one, so it is reachable
      at some address at every point. That is `segmentIp` in `lib/net.nix`, and
      it deploys with no disruption because nothing routes to it yet.

      Order, and each step is verifiable before the next:

      1. Point the Nest at `1.1.1.1`/`9.9.9.9`. The Pis are about to stop being
         reachable from it, and this is what keeps the house resolving while
         that is true
      2. Deploy the dual addresses to all three Pis. No disruption: they gain
         an address nothing routes to yet
      3. In the controller, define the four networks and set port profiles: the
         gate uplink as a trunk, the Pi ports untagged on servers. **Give the
         switch and the AP static addresses on servers while you are there**,
         because servers carries no DHCP pool: everything on it is statically
         addressed, which is both a better property for infrastructure and what
         keeps Kea off the trunk parent
      4. Move the uplink cable from the Nest to gate's ETH1
      5. Deploy the trunk config to gate. SSH to it over `wan` still works
         throughout, because `wan` is still on the Nest's LAN. Do this *after*
         the cable move rather than before: `service-sockets-require-all`
         means Kea fails while the trunk has no carrier, and systemd's start
         rate limit can leave the unit failed rather than retrying
      6. From gate, SSH to each Pi at its `192.168.20.x` address. It has no
         route off its segment yet, since the default gateway still points at
         the Nest, so give it one by hand and then make it permanent:
         `sudo ip route replace default via 192.168.20.1`, then `nrs`
      7. Revert the Nest's DNS

      The Pis keep their final octets, so `.32`, `.49` and `.11` mean the same
      hosts before and after.
- [ ] Tag SSIDs on the AP, one per segment that needs wireless
- [x] Inter-VLAN policy: trusted reaches servers; iot reaches servers on port
      53 only, so its lookups are filtered and visible in AdGuard without it
      being able to reach anything else; guest is internet-only and gets public
      resolvers rather than the fleet's, which is what makes "internet only"
      true rather than aspirational. Everything else is refused by the
      default-drop chain rather than by a deny rule
- [ ] Port-53 DNAT redirect for hardcoded resolvers, which works now that
      clients and Pis are on separate subnets
- [ ] Document the controller backup procedure in `README.md`

The controller database is state that lives outside the flake and is not
reproducible from Nix. Treat backing it up as a documented manual step.

**Exit test:** a device on iot cannot ping anything on trusted, and a client
with DNS hardcoded to 8.8.8.8 still shows up in AdGuard's logs.

## Settled switch topology

As of 2026-09-04, after the re-adoption above:

| port | contents |
|---|---|
| 5, 6, 7 | core4, lifeline, core5. Factory default, untagged |
| 8 | U7 Pro. Default native, **tagged** trusted, iot, guest |
| 9 | gate `lan0`. Default native, **tagged** trusted, iot, guest |

Switch management is static at `192.168.20.2`, the AP at `192.168.20.3`.

The invariant that keeps this working: **the untagged VLAN carries servers, and
nothing that has to be reachable in its default state lives on a tag.** gate
maps untagged to `192.168.20.0/24`, so any factory-defaulted device that
appears on any port is immediately addressable. Segments that exist for clients
rather than infrastructure, trusted and iot and guest, are tagged and reach
gate as `lan0.10`, `lan0.30` and `lan0.40`.

Both attempts to tidy this into "every segment is tagged" produced a deadlock
where a reset device could be neither reached nor adopted, and both needed
physical intervention to escape. The asymmetry is not untidiness, it is the
bootstrap path.

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

**Delete `"wan"` from `gate.sshInterfaces` in `lib/net.nix` as part of this.**
It is one line, and it is the difference between a router and a router with
sshd listening on the internet. It is listed here rather than left to memory
because the cable move is the exact moment that interface stops facing a
trusted LAN.

**The fleet renumber is already done.** `hosts.*.ip` moved into the servers
segment on 2026-09-02, ahead of this phase, because holding both the flat and
the segment address had stopped being free and started causing the failure
described under "Known gotchas". Nothing about the fleet's addressing changes
here, so this phase is now the cable move and the `sshInterfaces` edit alone.

**Exit test:** an external port scan of the WAN address shows nothing listening,
and a full reboot of `gate` brings the house back with no manual steps.

## Phase 8: afterwards

One at a time, weeks apart, once the house is boring.

- [ ] Alert when a host boots the wrong system. core5 fell back to its SD card
      on 2026-09-04 with a loose NVMe ribbon and ran a two-week-old generation
      for hours, looking healthy from every angle. Whatever the stack ends up
      being, it needs to compare each host's booted root device and running
      system generation against what the flake says it should be, because a
      host that is up, answering and wrong is invisible to liveness checks.
      See the NVMe section in README.md
- [ ] Decide the monitoring stack, then instrument `gate`. Deliberately not
      "wire gate into pimon": pimon does host liveness, and once the house
      routes through this box the questions are WAN state, conntrack pressure,
      per-interface throughput, DHCP pool exhaustion and DNS failure ratios,
      plus *alerting*, since a router fault you learn about by noticing the
      internet is broken is one monitoring did not catch.

      The conventional answer is Prometheus or VictoriaMetrics with Grafana on
      core5, scraping `node_exporter` fleet-wide plus exporters for AdGuard,
      UniFi and nftables. core5 is on NVMe as of 2026-08-31, which was the
      blocker: a TSDB writes harder and more continuously than even the UniFi
      database does, and that is not a workload for an SD card. pimon can stay as a
      liveness check or retire, but that is a choice to make rather than a
      default to inherit
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

**servers is the untagged native VLAN on the trunk, and that is load-bearing.**
A UniFi switch's own management interface rides the untagged native VLAN, and a
factory reset returns it there no matter what it was set to before. If gate
carries no untagged address, a reset switch has no path to the controller and
cannot be adopted, which is a deadlock that takes physical intervention to
escape.

This was learned the hard way on 2026-09-04. Making every segment tagged looked
tidier and cost two hours: the switch reset, came back on the native VLAN, and
could neither be reached nor adopted, while forwarding traffic perfectly the
whole time. Its own port profiles were the only reason servers had ever
appeared tagged, and those are ours to set.

So the trunk port on the switch must carry servers as its **native** network
with trusted, iot and guest tagged, matching `segmentOn` here. The property
worth preserving is that infrastructure is reachable in its default state,
without first being configured for a tag it does not yet know about.

## Re-adopting the Flex switch

The switch became unadoptable on 2026-09-02 and stayed that way. Three
independent blockers, each of which has to be cleared:

1. Its stored inform URL points at `192.168.86.49`, core5's retired flat-LAN
   address, which no longer exists anywhere
2. Device SSH is disabled on it, so `set-inform` cannot be used to repair that
   in place, and enabling device SSH is itself a setting pushed over inform
3. Its management rides the untagged native VLAN, which gate no longer
   addresses, so L2 discovery has no path to the controller

Each blocker's obvious fix needs one of the others already cleared, which is
why this needs a deliberate order rather than an attempt. **gate stays
reachable over `wan` throughout, and that is what makes the sequence safe: it
is the one path that does not depend on the switch.** That also means this has
to be done *before* Phase 7 moves `wan` to the modem.

1. **Forget the device in the controller first**, then factory reset the
   switch. Order matters and this is the step that was missed on 2026-09-04:
   two resets in a row appeared to fail because the controller still held the
   device record and auto-re-adopted within seconds, pushing the same broken
   saved config back onto it every time. The switch went straight from white
   to blue, never beaconed for adoption, and its management landed on a VLAN
   its own uplink did not carry, leaving it silent. Forgetting deletes the
   saved config so the reset has something to stick to.

   Hold reset until the LED changes, roughly ten seconds. **Watch the LED, not
   the clock: white means it worked, blue means it did not.** A short press
   only reboots, and the two are easy to confuse because both make the device
   drop and return
2. Nothing to do on gate. servers is the untagged native VLAN, and a
   factory-default switch tags nothing, so the two already agree. This step
   existed only while servers was tagged, and removing the need for it is why
   that was reverted
3. Adopt the switch in the controller. Discovery is L2 and everything now
   shares a VLAN, so it should appear on its own
4. **Change no native network on any port.** Add only tagged trusted, iot and
   guest to gate's uplink port and the AP's port, which is what SSIDs need.
   Everything else stays on the factory default.

   This is the step that cost hours on 2026-09-04 by being wrong. Setting a
   port's native network to the servers *network object* puts its traffic on
   VLAN 20, which splits it from the switch's own management on VLAN 1 and
   from every port still on the default. gate does not care what the switch
   calls the untagged VLAN: anything arriving untagged on `lan0` is
   `192.168.20.0/24` to it. So leaving every port on the default network
   already puts the Pis, the switch's management and gate on one segment, and
   a factory-defaulted device lands there too, reachable with no intervention
5. Set the statics: switch `.2`, AP `.3`. Then PR #54 can drop the
   transitional pool

The reset in step 1 is not optional and no lesser action clears blocker 1.

**A config change made while the controller cannot reach a device is queued,
not lost.** It applies whenever contact resumes, which may be much later and
during something unrelated. On 2026-09-04 a port profile set while core5 was
down landed minutes afterwards, mid-way through an unrelated gate deploy, and
flipped that port from tagged to untagged between two packet captures. It
looked exactly like the deploy had broken the network. If a change appears not
to have applied, assume it is pending rather than lost, and do not stack
another change on top of it.

Do not reassure yourself that port profiles live in the controller and come
back on adoption. They do, and on 2026-09-04 that was the problem rather than
the consolation: the saved profiles were what kept stranding the switch, and
discarding them via Forget is what finally broke the loop.

Useful signal while working: a factory-default UniFi device beacons for a
controller on UDP 10001 every few seconds. A switch sending only STP and LLDP,
with no DHCP and no beacon, is not waiting for adoption however default it
looks. `tcpdump -i lan0 -nn -e ether host <switch-mac>` on gate answers that in
twenty seconds and is worth reaching for before trying another reset.

**An address on the wrong wire fails silently, and in one direction.** Through
the Phase 6 cutover each Pi held its flat-LAN address alongside its segment
address, which is what kept it reachable while the switch uplink moved. Once
`end0` was carrying the servers VLAN, the flat address was unreachable from
everywhere, but it kept its directly-connected route: core5 both answered
nothing on `192.168.86.49` and sent everything bound for `192.168.86.0/24`
onto the servers VLAN rather than via gate. The visible symptom was the UniFi
controller reporting the switch as unreachable while gate could ping the same
switch fine. Dual addressing is the right tool during a cutover and a liability
the moment it finishes, so retire the old address in the same session that
completes the move rather than leaving it for a later phase.
