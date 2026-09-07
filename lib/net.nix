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
  # 192.168 rather than 10.x, and not for taste: a centrally managed VPN client
  # on one of the laptops here routes a wide slice of 10/8 into its tunnel, wide
  # enough to swallow a /16 picked anywhere in that space. A home LAN numbered
  # there would be unreachable from that machine whenever the tunnel was up, and
  # the policy is not ours to change locally. Managed profiles rarely claim
  # 192.168, because that is where home networks live. Verified with
  # `route -n get` against the tunnel rather than assumed.
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

    # One centrally managed laptop, and nothing else. Segmented for the same
    # reason guest is, but the threat model runs both ways: its software is
    # administered by someone else and cannot be audited from here, so on
    # trusted it could enumerate every device in the house. Equally, the house's
    # iot chatter has no business reaching a machine held to a security policy
    # that is not ours.
    #
    # This is not hypothetical. The 192.168 note above exists because that
    # machine's VPN client claims a wide slice of 10/8: it already makes routing
    # decisions on its administrator's behalf, not ours. This subnet is clear of
    # that range.
    #
    # It reaches the internet and the fleet resolvers on port 53, and nothing
    # else. Filtering is kept deliberately, but AdGuard's per-client settings
    # are where to disable query logging for it: a timestamped record of that
    # machine's lookups is an awkward thing to hold, in both directions, and
    # filtering does not require retaining it.
    work = {
      id = 50;
      subnet = "192.168.50.0/24";
      gateway = "192.168.50.1";
      prefixLength = 24;

      # Filtered, but not recorded. The paragraph above said AdGuard's
      # per-client settings are "where to disable query logging for it", which
      # left the property depending on someone having ticked a box in a UI.
      # modules/adguardhome.nix now reads this flag and writes that client on
      # every resolver, so it is a fact about the topology instead.
      #
      # This became load-bearing when gate started redirecting hardcoded
      # resolvers: before that, a machine on this segment ignoring DHCP was not
      # logged because it was not talking to the fleet at all.
      logQueries = false;
      pool = {
        first = "192.168.50.100";
        last = "192.168.50.240";
      };
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

    # gate (CWWK N100, 4x i226) has no `ip` and no `iface`. Both exist for the
    # hosts/common model of one host, one address, one default gateway, and
    # gate fits none of it: it holds `.1` in every segment and takes its default
    # route from the ISP over `wan`. There is no single address to name here and
    # nothing for hosts/common to configure, so its addresses are generated from
    # `segments` in hosts/gate/routing.nix instead.
    #
    # The WAN port is therefore `wanIface`, deliberately not `iface`. `iface`
    # means "the NIC hosts/common binds this host's static address and default
    # gateway to", and on a router that is a LAN port. Under the other name,
    # adding an `ip` here would silently configure a LAN address and a LAN
    # default gateway on the interface facing the internet.
    #
    # Nothing may assume gate has an `ip`: hosts/core5's pimon firewall and
    # modules/unbound's `allowFrom` both dereference `net.hosts.<h>.ip`
    # unguarded, so naming gate in either fails *that* host's evaluation rather
    # than gate's. modules/net-assertions.nix catches the `pimonAgents` half
    # with a message that names the cause; `allowFrom` is still bare.
    #
    # That is also the one thing likely to force an address here, when Phase 8
    # instruments gate. Decide what it would mean first: the honest answer is a
    # segment gateway, which is not what `ip` denotes for any other host in this
    # file.
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
      # `wan` was here while it was the management path, facing the Nest's LAN
      # rather than the internet. It was removed at the Phase 7 cutover on
      # 2026-09-05, once a trusted-segment path was proven: SSH from
      # 192.168.10.101 over `br-trusted`, verified before this line changed and
      # not after. Deleting it is the difference between a router and a router
      # with SSH on its WAN.
      #
      # `br-trusted` is where admin machines live. `lan0` is the trunk, whose
      # untagged VLAN is `servers`, so it is how the switch and AP reach the
      # controller. Both are listed, because this list is read literally: when
      # lan0 stopped meaning trusted and started meaning servers, the value
      # here did not change but its meaning did, and SSH silently became
      # reachable from vendor firmware and unreachable from a laptop. An
      # interface name is not a stable description of what is behind it.
      sshInterfaces = [
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
