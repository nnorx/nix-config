# Fleet network topology — single source of truth for LAN addressing.
#
# Hosts and modules read addresses from here instead of embedding literals, so
# a renumbering touches one file. Consumers reference attribute *names*, never
# values.
#
# The file is public and stays one file. Nothing in it identifies hardware: a
# device has a role name and an address here, and the MAC its address is
# reserved for is in gate's sops file. docs/device-identity.md has the split,
# what a role name may say, and why there is no private flake input.
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
    # else. Filtering is kept deliberately, but query logging is off (see
    # `logQueries` below): a timestamped record of that machine's lookups is an
    # awkward thing to hold, in both directions, and filtering does not require
    # retaining it.
    work = {
      id = 50;
      subnet = "192.168.50.0/24";
      gateway = "192.168.50.1";
      prefixLength = 24;

      # Filtered, but not recorded. modules/adguardhome.nix reads this flag and
      # writes the matching per-client rule on every resolver, so the property
      # holds without anyone having to tick a box in a UI.
      #
      # Load-bearing since gate started redirecting hardcoded resolvers: before
      # that, a machine here ignoring DHCP went unlogged because it was not
      # talking to the fleet at all.
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

    # Remote peers, over WireGuard terminating on gate. See "Inbound remote
    # access" in docs/router.md for the design.
    #
    # Not a VLAN: nothing on the switch carries it, and `id` only keeps the
    # third-octet convention and 60 out of use as a tag. No `pool` either,
    # because WireGuard has no DHCP. Each peer's address is fixed here, and it
    # is the peer's identity in gate's firewall: WireGuard drops any packet
    # whose source is not the address its key is bound to, so a source address
    # arriving on the tunnel is authenticated by the key that sent it.
    vpn = {
      id = 60;
      subnet = "192.168.60.0/24";
      gateway = "192.168.60.1";
      prefixLength = 24;
      peers = {
        forge = "192.168.60.10";
        phone = "192.168.60.20";
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
    # Nothing may assume gate has an `ip`: hosts/core5's pimon firewall
    # dereferences `net.hosts.<h>.ip` unguarded, so naming gate in
    # `pimonAgents` fails core5's evaluation rather than gate's.
    # modules/net-assertions.nix catches it with a message that names the
    # cause.
    #
    # Metrics did not force one either. What the scraper needs is narrower:
    # the address gate is reached at from the collector's segment, which is
    # `metricsSegment` below. docs/observability.md, "gate's address", has why.
    gate = {
      # The segment gate's exporters bind and are scraped on: its gateway
      # address there, and that address alone. hosts/gate/metrics.nix opens
      # their ports on the interface carrying it, to the collector alone.
      # modules/net-assertions.nix holds it to the collector's own segment, so
      # a scrape never crosses gate's forward chain.
      metricsSegment = "servers";

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
      #               AP for the switch uplink. See hosts/gate/routing.nix for
      #               why it is bridged rather than given its own subnet
      #   lan2  ETH3  spare, left down
      nics = {
        wan = "pci-0000:02:00.0";
        lan0 = "pci-0000:03:00.0";
        lan1 = "pci-0000:04:00.0";
        lan2 = "pci-0000:05:00.0";
      };
      wanIface = "wan";

      # The tagged trunk to the Flex switch, whose untagged VLAN is servers,
      # and the untagged port bridged into trusted. Named here, beside
      # `wanIface`, so hosts/gate reads one copy of each: a second copy is what
      # does not follow a rename, as `sshInterfaces` above shows.
      # modules/net-assertions.nix holds each role to a name in `nics`.
      trunkIface = "lan0";
      wiredIface = "lan1";

      # The WireGuard interface, carrying the `vpn` segment. Not in
      # `sshInterfaces`: that would open SSH to every peer, and only some may
      # have it, so hosts/gate/wireguard.nix opens it per peer instead.
      vpnIface = "wg0";
    };
  };

  # Devices a rule names: a role and an address, nothing that identifies the
  # hardware. Each one's MAC, which Kea reserves the address for, is
  # `mac-<name>` in secrets/gate.yaml. Addresses sit below the segment's pool,
  # in the range reserved for statics and reservations, so Kea leases them to
  # nothing else. A role name says what a rule needs and no more: no model, no
  # room (docs/device-identity.md, "What is identifying").
  devices = {
    govee-1 = {
      segment = "iot";
      ip = "192.168.30.21";
    };
    govee-2 = {
      segment = "iot";
      ip = "192.168.30.22";
    };
    govee-3 = {
      segment = "iot";
      ip = "192.168.30.23";
    };
  };

  # The Govee lights, for the rules in hosts/gate/govee.nix and core5. Named
  # rather than derived from `devices`, like pimonAgents: a rule reads a role,
  # not "every device on iot".
  goveeLights = [
    "govee-1"
    "govee-2"
    "govee-3"
  ];

  # The MTU of the WireGuard tunnel, on gate and on every peer. WireGuard's
  # default is 1420, which assumes a clean 1500-byte path. Mobile networks are
  # not one: over a T-Mobile hotspot, measured 2026-10-02 with don't-fragment
  # pings through the tunnel, the largest inner packet that survived was 1376
  # bytes, so about 1436 on the wire once WireGuard's 60 bytes of IPv4
  # framing are added. Anything bigger, which is an SSH key exchange or most
  # of a web page, vanished without an error, while pings and the handshake
  # itself worked, so the tunnel looked up and carried nothing.
  #
  # 1280 is as low as it can go: the full-tunnel profile carries IPv6 inside,
  # and IPv6 refuses a link smaller than that. On the wire it is 1340 bytes,
  # with ample room under that measurement and under most mobile and hotel
  # paths, though not a guarantee on all of them. TCP negotiates its segments
  # down to match, at a cost of a few percent of throughput. Peers configured
  # by hand, like the phone, need the same value set in their app.
  vpnMtu = 1280;

  # The fleet's DNS resolvers, AdGuard over Unbound, which DHCP hands out and
  # gate redirects stray port-53 traffic to. Named by host so consumers can
  # read both the address and the segment it sits on.
  resolvers = [
    "core4"
    "lifeline"
  ];

  # The name core5 asks each resolver every 30 seconds, to see that it answers
  # (modules/blackbox.nix). In `lan`, which Unbound answers NXDOMAIN itself
  # (modules/unbound.nix), so the probe needs neither the WAN nor the cache, and
  # AdGuard leaves it out of its log and statistics (modules/adguardhome.nix).
  resolverProbe = "resolver-probe.lan";

  # Public resolvers, for what must not depend on the fleet's own: AdGuard's
  # bootstrap and fallback, core5, and the guest segment. Two operators, so
  # one outage does not take both, and not Google: keeping it out of the DNS
  # path is one of the reasons this fleet exists.
  publicResolvers = [
    "1.1.1.1" # Cloudflare
    "9.9.9.9" # Quad9
  ];

  # forge's DNS away from home, over TLS: hosts/forge/dns.nix. `name` is what
  # the certificate must carry. One operator at both of its addresses rather
  # than two operators, since systemd-resolved stays on whichever server last
  # answered, so a second operator would collect lookups after any hiccup in
  # the first. Quad9 because it is already one of the two above, keeps no
  # client addresses, sends no client subnet from these two, and refuses
  # known-malicious names, which is some of what AdGuard does at home.
  encryptedResolvers = [
    {
      ip = "9.9.9.9";
      name = "dns.quad9.net";
    }
    {
      ip = "149.112.112.112";
      name = "dns.quad9.net";
    }
  ];

  # Where each Unbound fetches its copy of the root zone (RFC 8806,
  # modules/unbound.nix): the root servers that allow zone transfers, and
  # ICANN's two transfer hosts. The list Unbound's own example configuration
  # carries, in the version this flake pins. IPv4 alone, since Unbound
  # recurses over IPv4 alone. Unbound tries them in turn, so one going away
  # costs a timeout, and all of them going away costs the local copy, not
  # resolution: the resolvers fall back to asking the root.
  rootZoneSources = [
    "170.247.170.2" # b.root-servers.net
    "192.33.4.12" # c.root-servers.net
    "199.7.91.13" # d.root-servers.net
    "192.5.5.241" # f.root-servers.net
    "192.112.36.4" # g.root-servers.net
    "193.0.14.129" # k.root-servers.net
    "192.0.47.132" # xfr.cjr.dns.icann.org
    "192.0.32.132" # xfr.lax.dns.icann.org
  ];

  # The multicast group Govee lights listen on for the LAN API's scan. It is
  # SSDP's group, but gate lets only `ports.goveeScan` through to iot, not
  # SSDP's own port.
  goveeGroup = "239.255.255.250";

  # Hosts running a pimon agent that report to the collector on core5. Named
  # rather than derived from `hosts`: address presence is not the same fact as
  # running an agent, and core5's firewall opens a port per entry.
  pimonAgents = [
    "core4"
    "lifeline"
  ];

  # The fleet's metrics, by pull: the collector runs the store and Grafana
  # (modules/metrics.nix) and scrapes node_exporter on each target
  # (modules/node-exporter.nix), which opens its port to the collector alone.
  # See docs/observability.md. Named rather than derived from `hosts`, for the
  # same reason as pimonAgents: being a host is not the same fact as being
  # scraped. gate has no `ip`, and is scraped at its `metricsSegment`.
  metricsCollector = "core5";
  metricsTargets = [
    "core4"
    "lifeline"
    "core5"
    "gate"
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

    # Home Assistant's frontend and API, on core5. Phones on trusted reach it,
    # which gate's "trusted reaches servers" rule already allows. No WireGuard
    # peer does: nothing in hosts/gate/wireguard.nix grants it.
    homeAssistant = 8123;

    # Govee's LAN API, between Home Assistant on core5 and the lights on iot.
    # The numbers are Govee's, fixed in the lights' firmware. gate routes the
    # scan into iot and lets the other two cross; see hosts/gate/govee.nix.
    goveeScan = 4001; # UDP, multicast discovery, to the lights
    goveeReply = 4002; # UDP, scan replies and status, to core5
    goveeCommand = 4003; # UDP, control, to each light

    # The metrics stack, docs/observability.md. node_exporter is a contract
    # between core5 and every target. VictoriaMetrics listens on core5's
    # loopback and is here because the rule is every port. Grafana is on
    # core5's address, at 3030 rather than its default 3000, which is
    # adguardWeb: gate's tunnel grants match on the number.
    nodeExporter = 9100;
    victoriaMetrics = 8428;
    grafana = 3030;

    # The alerting on the collector, on its loopback (modules/alerting.nix).
    # vmalert's own default, 8880, is the UniFi controller's guest portal on
    # the same host, though nothing publishes that.
    vmalert = 8881;
    alertmanager = 9093;

    # Kea's statistics, on gate's metricsSegment address beside node_exporter.
    # Kea keeps pool usage itself but serves it only as JSON over its control
    # socket, which this exporter translates.
    keaExporter = 9547;

    # Unbound's statistics, on each resolver's address beside node_exporter,
    # read over Unbound's local control socket (modules/unbound.nix).
    unboundExporter = 9167;

    # Probes from core5, on its loopback: DNS to each resolver, ICMP to the
    # public resolvers (modules/blackbox.nix).
    blackboxExporter = 9115;

    # The NVMe drive's own health log, on core5's loopback
    # (modules/smartctl.nix).
    smartctlExporter = 9633;

    # WireGuard on gate's WAN, which every peer's config names. 443 rather
    # than 51820, because restrictive Wi-Fi blocks unusual UDP ports more often
    # than the one HTTP/3 uses.
    wireguard = 443;
  };
}
