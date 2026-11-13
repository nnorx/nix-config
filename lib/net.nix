# The fleet's network topology, the one source of LAN addressing. Consumers
# read attribute names, never values, so renumbering touches one file. Nothing
# here identifies hardware: a device has a role name and an address, and its
# MAC is in gate's sops file (docs/network.md, "Naming a device").
{
  # The third octet is the VLAN id. gate holds .1 in every segment
  # (`gateway`); below .100 is statics and reservations, .100-.240 the pool,
  # and .241+ is left alone. 192.168 rather than 10/8, because a managed VPN
  # client on one laptop routes a wide slice of 10/8 into its tunnel.
  # `subnet` is explicit because Kea and nftables want CIDR.
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

    # The Pis, the switch, the AP. Reachable from trusted. Its own segment
    # because the port-53 redirect keeps the client's source only across
    # subnets: on one, the reply comes from an address the client never asked.
    #
    # No `pool`: its devices are static, so they do not depend on DHCP, and
    # Kea stays off the trunk parent `lan0`, where raw sockets also see tagged
    # frames (AF_PACKET before VLAN demux) and would hand iot devices servers
    # addresses. hosts/gate/routing.nix serves DHCP only where a pool exists.
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

    # One centrally managed laptop. Isolated both ways: its software cannot be
    # audited from here, and the house's traffic has no business reaching a
    # machine held to someone else's policy. It reaches the internet and the
    # fleet resolvers on port 53, and nothing else.
    work = {
      id = 50;
      subnet = "192.168.50.0/24";
      gateway = "192.168.50.1";
      prefixLength = 24;

      # Filtered but not logged, since a record of that machine's lookups is
      # not ours to hold. modules/adguardhome.nix reads this on every resolver.
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

    # Remote peers over WireGuard on gate ("Inbound remote access" in
    # docs/router.md). Not a VLAN: `id` keeps the third-octet convention and
    # keeps 60 out of use as a tag. No pool. A peer's address is its identity
    # in gate's firewall, authenticated by its key: WireGuard drops a packet
    # whose source is not the address bound to the key that sent it.
    vpn = {
      id = 60;
      subnet = "192.168.60.0/24";
      gateway = "192.168.60.1";
      prefixLength = 24;
      peers = {
        forge = "192.168.60.10";
        phone = "192.168.60.20";
      };

      # What each peer may reach beyond DNS, read by gate's forward rules:
      #   adguard   the AdGuard UI on the fleet resolvers
      #   ssh       SSH to every server, and to gate itself
      #   internet  out `wan`, for a full-tunnel profile
      # Nothing grants the UniFi UI, which administers the network. The phone
      # gets DNS only, as the device most likely to be lost.
      #
      # DNS is every peer's and not a grant, because it cannot be refused: port
      # 53 is redirected on the tunnel too, ahead of every tunnel rule. The
      # tunnel does not work from the LAN, where a packet to gate's public
      # address arrives on a LAN interface. modules/net-assertions.nix checks
      # every entry.
      grants = {
        forge = [
          "adguard"
          "ssh"
          "internet"
        ];
        phone = [ ];
      };

      # Each but `internet` is a forward rule in hosts/gate/wireguard.nix,
      # which asserts that its rules and this list agree.
      grantNames = [
        "adguard"
        "ssh"
        "internet"
      ];
    };
  };

  # Per-host wired NIC. The Pi 4 and 5 name their onboard NIC end0.
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

    # Second, independent DNS path.
    lifeline = {
      ip = "192.168.20.11";

      iface = "end0";
      segment = "servers";
      sshInterfaces = [ "end0" ];
    };

    # gate (CWWK N100, 4x i226) has no `ip` or `iface`, which serve
    # hosts/common's one address and gateway: it holds .1 in every segment
    # (hosts/gate/routing.nix) and routes out `wan`. The WAN port is
    # `wanIface`, not `iface`, so an `ip` added here cannot configure a LAN
    # address on the port facing the internet. Nothing may assume gate has an
    # `ip`: consumers read `.ip` unguarded for the hosts a list names, so a list
    # that may name gate reads it another way, as `metricsTargets` does.
    gate = {
      # The segment gate's exporters bind and are scraped on, at its gateway
      # address. modules/net-assertions.nix holds it to the collector's
      # segment, so a scrape never crosses gate's forward chain.
      metricsSegment = "servers";

      # Listed rather than derived, because this is a security control: a new
      # interface must not become an SSH surface unasked. Never `wan`. Before
      # removing one, prove SSH over another. `br-trusted` holds the admin
      # machines; `lan0` is the trunk, untagged servers. Read literally: an
      # interface name is not a stable description of what is behind it.
      sshInterfaces = [
        "lan0"
        "br-trusted"
      ];

      # Role names, pinned to PCI paths by .link files in hosts/gate; the
      # kernel never generates names in this shape. A PCI path rather than a
      # MAC, so a systemd naming change cannot reorder the ports and no
      # hardware id enters the repo; a MAC check after the rename catches
      # firmware renumbering the buses. Sockets ETH0-ETH3 map in order.
      #   wan   ETH0  the modem
      #   lan0  ETH1  tagged trunk to the Flex switch, every segment on it
      #   lan1  ETH2  untagged trusted, a dedicated 2.5G run to one machine,
      #               bridged (see hosts/gate/routing.nix)
      #   lan2  ETH3  spare, left down
      nics = {
        wan = "pci-0000:02:00.0";
        lan0 = "pci-0000:03:00.0";
        lan1 = "pci-0000:04:00.0";
        lan2 = "pci-0000:05:00.0";
      };
      wanIface = "wan";

      # Named here beside `wanIface` so hosts/gate reads one copy of each,
      # which follows a rename. modules/net-assertions.nix holds each to `nics`.
      trunkIface = "lan0";
      wiredIface = "lan1";

      # Not in `sshInterfaces`, which would open SSH to every peer;
      # hosts/gate/wireguard.nix opens it per peer.
      vpnIface = "wg0";
    };
  };

  # Devices a rule names, by role. Each one's MAC is `mac-<name>` in
  # secrets/gate.yaml, and its address sits below the pool, so Kea leases it
  # to nothing else. A role name says what a rule needs: no model, no room.
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

  # For hosts/gate/govee.nix and core5. Named rather than derived from
  # `devices`: a rule reads a role, not "every device on iot".
  goveeLights = [
    "govee-1"
    "govee-2"
    "govee-3"
  ];

  # The tunnel MTU, on gate and every peer. Over a mobile hotspot,
  # don't-fragment pings found 1376 the largest inner packet to survive (1436
  # on the wire); larger ones vanished silently, so WireGuard's default 1420
  # left the tunnel up and carrying nothing. 1280 is the floor, because IPv6
  # inside the tunnel refuses anything smaller: 1340 on the wire. Peers set by
  # hand, like the phone, need it in their app.
  vpnMtu = 1280;

  # AdGuard over Unbound, handed out by DHCP and the target of gate's port-53
  # redirect. Named by host, so consumers read both address and segment.
  resolvers = [
    "core4"
    "lifeline"
  ];

  # What core5's probe asks each resolver (modules/blackbox.nix). Unbound
  # answers it NXDOMAIN itself, so the probe needs neither the WAN nor the
  # cache, and AdGuard leaves it out of its log (modules/adguardhome.nix).
  resolverProbe = "resolver-probe.lan";

  # For what must not depend on the fleet's own: AdGuard's bootstrap, core5
  # and guest. Two operators, so one outage does not take both, and not
  # Google, which the fleet exists partly to keep out of its DNS path.
  publicResolvers = [
    "1.1.1.1" # Cloudflare
    "9.9.9.9" # Quad9
  ];

  # forge's DNS away from home, over TLS (hosts/forge/dns.nix). One operator,
  # since systemd-resolved stays on whichever server last answered, so a
  # second would collect lookups after any hiccup in the first. Quad9 keeps no
  # client addresses and refuses known-malicious names, as AdGuard does.
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

  # Where each Unbound fetches the root zone (RFC 8806, modules/unbound.nix):
  # the list from Unbound's example configuration, IPv4 alone as Unbound
  # recurses over IPv4. Losing them all costs the local copy, not resolution.
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

  # The Govee LAN API's scan group. It is SSDP's, but gate lets only
  # `ports.goveeScan` through to iot.
  goveeGroup = "239.255.255.250";

  # Named rather than derived from `hosts`, since each target opens a port to
  # the collector (docs/observability.md). gate is scraped at `metricsSegment`.
  metricsCollector = "core5";
  metricsTargets = [
    "core4"
    "lifeline"
    "core5"
    "gate"
  ];

  # Ports forming contracts between hosts, so they cannot live in one module:
  # each resolver's AdGuard dials its own unbound; each opens adguardWeb.
  ports = {
    unbound = 5335;

    adguardWeb = 3000;

    # UniFi controller, in containers on core5, which the switch and AP reach.
    unifiUi = 8443; # HTTPS admin UI
    unifiInform = 8080; # devices POST their state here
    unifiStun = 3478; # UDP, keeps devices reachable behind NAT
    unifiDiscovery = 10001; # UDP, device discovery

    # Home Assistant on core5, reached from trusted; no tunnel grant names it.
    homeAssistant = 8123;

    # Govee's LAN API, fixed in the lights' firmware; see hosts/gate/govee.nix.
    goveeScan = 4001; # UDP, multicast discovery, to the lights
    goveeReply = 4002; # UDP, scan replies and status, to core5
    goveeCommand = 4003; # UDP, control, to each light

    # The metrics stack (docs/observability.md). vmauth holds the store's
    # default port and passes reads alone, so a query there goes through it.
    # Grafana is at 3030, since 3000 is adguardWeb and tunnel grants match on
    # the number.
    nodeExporter = 9100;
    victoriaMetrics = 8428;
    victoriaMetricsStore = 8430;
    grafana = 3030;

    # On the collector's loopback (modules/alerting.nix). vmalert's default,
    # 8880, is the UniFi guest portal on the same host.
    vmalert = 8881;
    alertmanager = 9093;

    # Kea's pool usage, from its control socket, on gate's metricsSegment.
    keaExporter = 9547;

    # Unbound's statistics, from its control socket (modules/unbound.nix).
    unboundExporter = 9167;

    # core5's DNS and ICMP probes, on its loopback (modules/blackbox.nix).
    blackboxExporter = 9115;

    # The NVMe drive's health log, on core5's loopback (modules/smartctl.nix).
    smartctlExporter = 9633;

    # Tang on core5 and lifeline, which gate's initrd asks to unlock its disk.
    tang = 7654;

    # WireGuard on gate's WAN. 443 rather than 51820, because restrictive
    # Wi-Fi blocks unusual UDP ports more often than HTTP/3's.
    wireguard = 443;
  };

  # The house's web UIs, at https://<name>.<domain> through each host's proxy;
  # <domain> is `services-domain` in sops, never here. `upstream` ("http") and
  # `grantable` (true) are optional, defaulted in the readers, and
  # modules/net-assertions.nix refuses an attribute it does not know.
  services = {
    grafana = {
      host = "core5";
      # A name in `ports`: where the service listens, on loopback.
      port = "grafana";
      # Segments that reach it; what a peer reaches is `segments.vpn.grants`.
      segments = [ "trusted" ];
      # What core5's probe asks for. It must answer without a login.
      probe = "/api/health";
      # The offboxPush entry backing up its state; null, as it is provisioned.
      backup = null;
    };
  };
}
