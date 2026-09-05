# Fleet network topology — single source of truth for LAN addressing.
#
# Hosts and modules read addresses from here instead of embedding literals, so
# a renumbering touches one file. Consumers reference attribute *names*, never
# values, which keeps the option open of moving this file into a private flake
# input later without editing anything that reads it.
{
  # The live topology. Every host and every DHCP client is addressed from
  # here; the flat network the fleet grew up on is gone.
  #
  # The third octet is the VLAN id, so an address names its own segment.
  #
  # 192.168 rather than 10.x, and not for taste: Cloudflare WARP routes
  # 10.8.0.0/13 into its tunnel on Nick's work profile, which swallows
  # 10.10.0.0/16 whole. A home LAN numbered there would be unreachable from his
  # own laptop whenever WARP was connected, and that profile is managed by the
  # employer, so it could not be excluded locally. Corporate profiles rarely
  # claim 192.168 space, because employees' home networks live there. Verified
  # with `route -n get` against the tunnel rather than assumed.
  #
  # These do not collide with the 192.168.86.0/24 the Nest hands out today, so
  # both schemes coexist through the transition.
  #
  # `subnet` is carried explicitly rather than derived from gateway and prefix:
  # Kea and nftables both want the network address in CIDR form, and deriving
  # it in Nix means string arithmetic on octets for no gain.
  #
  # gate holds .1 in every segment: that is what `gateway` is. Below .100 is
  # reserved for statics and DHCP reservations, .100-.240 is the dynamic pool,
  # and .241+ is left alone.
  segments = {
    # Laptops and phones. Full access.
    trusted = {
      id = 10;
      subnet = "192.168.10.0/24";
      gateway = "192.168.10.1";
      prefixLength = 24;
      pool = {
        first = "192.168.10.100";
        last = "192.168.10.240";
      };
    };

    # The Pis, the switch, the AP. Reachable from trusted.
    #
    # Separate from trusted for a specific mechanical reason, not tidiness:
    # the port-53 redirect that catches hardcoded resolvers only preserves the
    # client's source address when the resolver is on a *different* subnet. On
    # the same subnet the reply comes back from an address the client never
    # sent to, so it drops it, and masquerading the hairpin to fix that
    # destroys the source address the redirect existed to preserve.
    # No `pool`, deliberately, and that absence is load-bearing in two ways.
    #
    # Everything here is statically addressed: the Pis from their own NixOS
    # config, the switch and the AP from the UniFi controller. Infrastructure
    # that does not depend on DHCP being up is a better property for the
    # devices the rest of the network is reached through.
    #
    # It is also what keeps Kea off the trunk parent. servers is the untagged
    # VLAN on `lan0`, and Kea's raw sockets on a trunk parent also receive
    # tagged frames, because the kernel delivers to AF_PACKET taps before VLAN
    # demux. A DHCP request from an iot device would arrive on `lan0.30` *and*
    # on `lan0`, and the `lan0` copy would be answered from this pool. The
    # device would end up with a servers address while physically on VLAN 30,
    # which does not work at all: gate would ARP for it untagged and never find
    # it. hosts/gate/routing.nix serves DHCP only where a pool exists, so no
    # pool here means nothing binds `lan0`.
    servers = {
      id = 20;
      subnet = "192.168.20.0/24";
      gateway = "192.168.20.1";
      prefixLength = 24;

      # TRANSITIONAL POOL, to be removed once the switch and AP hold static
      # addresses. See the comment above about why servers has none normally.
      #
      # Both devices came from the pre-trunk config holding leases in
      # 192.168.10.0/24, which is now the *trusted* subnet on a VLAN they are
      # not on. So they are unreachable, and they cannot be given static
      # addresses because that needs the controller, which needs core5, which
      # needs gate to be answering on servers. A pool breaks that loop: they
      # pick up 192.168.20.x by themselves and the controller can renumber them
      # deliberately afterwards.
      #
      # The trunk-parent hazard this reintroduces is real but currently inert:
      # it misdirects DHCP requests arriving tagged from iot or guest, and
      # nothing is on either segment yet.
      pool = {
        first = "192.168.20.100";
        last = "192.168.20.150";
      };
    };

    # Cameras, plugs, TVs. No LAN access, WAN only.
    iot = {
      id = 30;
      subnet = "192.168.30.0/24";
      gateway = "192.168.30.1";
      prefixLength = 24;
      pool = {
        first = "192.168.30.100";
        last = "192.168.30.240";
      };
    };

    # The trunk's untagged native VLAN, and the only segment that exists for
    # infrastructure rather than for hosts. UniFi switches and APs put their
    # own management on the native VLAN, and a factory reset returns them there
    # regardless of what they were configured with. Giving that VLAN a real
    # subnet is what makes a reset device reachable, and therefore adoptable,
    # without a cable move or a console.
    #
    # 192.168.1.0/24 is not an accident and not the convention's third-octet
    # rule either, though it happens to satisfy it. Ubiquiti devices in their
    # factory state fall back to a static 192.168.1.20 when no DHCP answers, so
    # numbering this VLAN here means a defaulted device is reachable from gate
    # even with no lease to give it.
    #
    # Deliberately no pool. Kea binds only where a segment declares one, and
    # binding the trunk parent is what the comment at the bottom of
    # hosts/gate/routing.nix warns against: raw sockets there see tagged frames
    # too, so an iot client would be offered an address from this subnet as
    # well as its own. Infrastructure gets static addresses from the
    # controller instead, which is where the rest of its config lives anyway.
    mgmt = {
      id = 1;
      subnet = "192.168.1.0/24";
      gateway = "192.168.1.1";
      prefixLength = 24;
    };

    # Visitors. Internet only, client isolation on.
    guest = {
      id = 40;
      subnet = "192.168.40.0/24";
      gateway = "192.168.40.1";
      prefixLength = 24;
      pool = {
        first = "192.168.40.100";
        last = "192.168.40.240";
      };
    };
  };

  # Per-host wired NIC. `iface` is the kernel name — the Pi 4 and 5 enumerate
  # their onboard NIC as end0.
  hosts = {
    core4 = {
      ip = "192.168.20.32";

      iface = "end0";
      segment = "servers";
      sshInterfaces = [ "end0" ];
    };
    core5 = {
      ip = "192.168.20.49";

      iface = "end0";
      segment = "servers";
      sshInterfaces = [ "end0" ];
    };

    # Second, independent DNS path. Static, like the other servers-segment
    # hosts: that segment carries no DHCP pool at all, so nothing can be
    # leased an address that collides with one of these.
    lifeline = {
      ip = "192.168.20.11";

      iface = "end0";
      segment = "servers";
      sshInterfaces = [ "end0" ];
    };

    # gate (CWWK N100, 4x i226) deliberately has no `ip` yet: it keeps its DHCP
    # lease from the Nest until the router subnets are settled, so pinning one
    # here would be fiction.
    #
    # The WAN port is `wanIface`, deliberately not `iface`. `iface` means "the
    # NIC hosts/common binds this host's static address and default gateway to",
    # and on a router that is a LAN port. Naming the WAN port `iface` would mean
    # that the moment gate gains an `ip`, hosts/common silently configures the
    # LAN address and the LAN default gateway on the interface facing the
    # internet. gate gets an `iface` of its own when the LAN side exists.
    #
    # Until then it has no `ip`, and nothing may assume otherwise: hosts/core5's
    # pimon firewall and modules/unbound's allowFrom both dereference
    # `net.hosts.<h>.ip` unguarded, so adding gate to `pimonAgents` or to an
    # `allowFrom` before it is addressed fails *that* host's evaluation, not
    # gate's.
    gate = {
      # Role names, and the PCI path each is pinned to. hosts/gate turns these
      # into systemd .link files; the kernel never generates names in this
      # shape, so there is no rename collision.
      #
      # Matching on PCI path rather than MAC address is deliberate. It defends
      # against the thing that actually reorders interfaces, which is systemd's
      # predictable-naming scheme changing between releases and turning enp2s0
      # into something else, while keeping hardware identifiers out of a public
      # repo. See "What stays out of this repo" in docs/router.md. The residual
      # risk it does not cover is firmware renumbering the PCI buses, which
      # fixed hardware with no hotplug does not do, and which a MAC check after
      # the rename catches.
      #
      # Physical sockets are labelled ETH0-ETH3 on the chassis and map in
      # order, so wan is ETH0.
      #
      # Roles, settled in Phase 1:
      #   wan   ETH0  the modem
      #   lan0  ETH1  tagged trunk to the Flex switch, every segment on it
      #   lan1  ETH2  untagged, bridged into trusted: a dedicated 2.5G run to
      #               one machine that does not contend with the Pis and the
      #               AP for the switch uplink. Bridged rather than given its
      #               own subnet so it shares a broadcast domain with the rest
      #               of trusted, which is what mDNS and friends need to see
      #               phones and printers
      #   lan2  ETH3  spare, left down
      # Interfaces sshd is reachable on. Listed rather than derived, because
      # this is a security control and deriving it would mean a future
      # interface silently becoming an SSH surface.
      #
      # `wan` is here only because it is still the management path: it faces
      # the Nest's LAN, not the internet. **Remove it at the Phase 7 cutover**,
      # once management lives on the LAN side. That deletion is the difference
      # between a router and a router with SSH on its WAN.
      #
      # `br-trusted` is where admin machines live. `lan0` is the trunk, whose
      # untagged VLAN is `servers`, so it is how the switch and AP reach the
      # controller. Both are listed, because this list is read literally: when
      # lan0 stopped meaning trusted and started meaning servers, the value
      # here did not change but its meaning did, and SSH silently became
      # reachable from vendor firmware and unreachable from a laptop. An
      # interface name is not a stable description of what is behind it.
      sshInterfaces = [
        "wan"
        "lan0"
        "br-trusted"
      ];

      nics = {
        wan = "pci-0000:02:00.0";
        lan0 = "pci-0000:03:00.0";
        lan1 = "pci-0000:04:00.0";
        lan2 = "pci-0000:05:00.0";
      };
      wanIface = "wan";
    };
  };

  # Hosts running a pimon agent that report to the collector on core5. Named
  # rather than derived from `hosts`: address presence is not the same fact as
  # running an agent, and core5's firewall opens a port per entry.
  pimonAgents = [
    "core4"
    "lifeline"
  ];

  # Ports forming contracts *between* hosts, so they can't live in one module:
  # core4 and lifeline each dial their own unbound on loopback; both dial
  # core5's pimon collector; every AdGuard host opens adguardWeb on its LAN
  # interface.
  ports = {
    unbound = 5335;

    # Moved off 8080 for the UniFi controller, whose device-inform port is
    # 8080 and is baked into UniFi device firmware defaults. pimon is ours and
    # has no external contract, so it is the one that moves. Every consumer
    # reads this attribute, so the change lands everywhere at once: the
    # collector's bind, both agents' collectorUrl, and core5's firewall.
    pimon = 8090;

    adguardWeb = 3000;

    # UniFi controller, in containers on core5. Ports the switch and AP need
    # to reach, so they are contracts between hosts like the rest of this set.
    unifiUi = 8443; # HTTPS admin UI
    unifiInform = 8080; # devices POST their state here
    unifiStun = 3478; # UDP, keeps devices reachable behind NAT
    unifiDiscovery = 10001; # UDP, device discovery
  };
}
