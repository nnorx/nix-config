# gate routes, for all four segments.
#
# Still behind the Nest: `wan` keeps its DHCP lease, so this is double NAT,
# which breaks inbound and UPnP and nothing here depends on either.
#
# `lan0` is the tagged trunk to the Flex switch. `servers` is the *untagged*
# VLAN on it, deliberately: the switch and the AP have to reach the controller
# to be managed at all, and an infrastructure device that can only be reached
# over a tag it has not been configured with yet is a chicken-and-egg problem.
#
# That choice moved the meaning of `lan0` from trusted to servers without
# changing its name, which silently repointed `sshInterfaces` in lib/net.nix at
# the segment holding vendor firmware and away from the one holding laptops.
# `br-trusted` is listed there now. An interface name is not a stable
# description of what is behind it.
#
# `lan1` is untagged trusted, bridged with the tagged trusted VLAN rather than
# given a subnet of its own, so a machine cabled directly to gate shares a
# broadcast domain with the phones and laptops on Wi-Fi. Separate subnets would
# break mDNS between them, which surfaces later as printer and cast discovery
# quietly not working.
#
# One caveat on that bridge: bridged frames bypass the forward chain, which is
# why `filterForward` does not break it. If `br_netfilter` is ever loaded, and
# container runtimes load it automatically, bridged frames start traversing the
# forward chain as `iifname lan1 oifname lan0.10`, match nothing, and are
# dropped by the default policy. The symptom is exactly the discovery failure
# this bridge exists to prevent, and it is invisible in `nft list ruleset`.
# gate runs no containers today; if that changes, this needs revisiting.
#
# **Do not deploy this before the switch uplink physically moves to lan0.**
# An earlier version of this comment claimed the change was inert until then.
# It is not: `service-sockets-require-all` spans four interfaces, none of which
# has carrier until the trunk is cabled, so Kea fails its retries, exits, and
# `Restart=on-failure` loops it indefinitely. Merging is safe; deploying is
# part of the cable move, not a step before it.
{
  lib,
  net,
  ...
}:
let
  seg = net.segments;

  # Interface names, bound once each. They appear in the addresses, the Kea
  # listeners and subnets, the nat internal list, the firewall scopes and the
  # forward rules, and those drifting apart is how this class of bug happens.
  trunk = "lan0"; # tagged trunk to the Flex switch; untagged = servers
  wired = "lan1"; # untagged trusted, a dedicated run to one machine
  trustedBr = "br-trusted"; # tagged trusted + `wired`, so they share a domain
  wan = net.hosts.gate.wanIface; # bound here too, since a forward rule names it

  # 802.1q sub-interface for a tagged segment.
  tagged = name: "${trunk}.${toString seg.${name}.id}";

  # Everything except servers, which is the untagged VLAN on the trunk and so
  # has no sub-interface. The `vlans` block is derived from this rather than
  # written out, so a new tagged segment cannot be added to the topology and
  # forgotten here, which would leave it with an address, a subnet, a firewall
  # scope and a nat entry for an interface that is never created.
  taggedSegments = [
    "trusted"
    "iot"
    "work"
    "guest"
  ];

  # Which segment each routed interface carries, by name. Addresses, Kea
  # subnets, nat internals and firewall scopes are all generated from this.
  segmentOn = {
    ${trustedBr} = "trusted";
    ${trunk} = "servers"; # untagged on the trunk
    ${tagged "iot"} = "iot";
    ${tagged "work"} = "work";
    ${tagged "guest"} = "guest";
  };

  # Bound once rather than recomputed at each call site, for the same reason
  # the interface names above are.
  segmentIfaces = builtins.attrNames segmentOn;

  # DHCP is served where a segment declares a pool, and nowhere else. servers
  # declares none: it is statically addressed, and it is the untagged VLAN on
  # the trunk, so binding it would put Kea on the trunk parent. See the
  # comment on `servers` in lib/net.nix.
  dhcpOn = lib.filterAttrs (_: name: seg.${name} ? pool) segmentOn;
  dhcpIfaces = builtins.attrNames dhcpOn;

  # Everything upstream of gate that is not the internet. The only RFC1918
  # destination reachable out `wan` is the ISP device's own management
  # interface, and every segment can reach it today: `networking.nat` emits a
  # single blanket `iifname { all segments } oifname wan accept`, which does not
  # care what the destination is.
  #
  # "A guest's phone can reach the box that terminates the house's internet" is
  # not a property worth having, and less so while that box's credentials may be
  # whatever is printed on its label. The same goes for a compromised camera on
  # iot, or a corporate laptop on work. servers is denied too, and has the
  # strongest case of any of them: it carries the switch and the AP, whose
  # unaudited firmware is the same reason `sshInterfaces` had to name
  # `br-trusted` rather than `lan0`.
  #
  # Derived by exclusion rather than listed, so a segment added later is denied
  # by default instead of quietly inheriting the exception. If the ISP device is
  # ever bridged, this keeps matching rather than going inert: private space is
  # never a legitimate destination out `wan`, so it stays correct instead of
  # becoming vestigial.
  upstreamPrivate = [
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "169.254.0.0/16"
    "100.64.0.0/10" # CGNAT: docs/router.md leaves this open, so cover it
  ];
  managesUpstream = [ trustedBr ];
  deniedUpstream = lib.filter (i: !(builtins.elem i managesUpstream)) segmentIfaces;

  nftSet = xs: "{ ${lib.concatStringsSep ", " xs} }";
  quoted = map (x: "\"${x}\"");

  # The fleet's own resolvers. Handing these out directly, rather than gate
  # proxying to them, is what keeps AdGuard's per-client attribution
  # meaningful.
  #
  # The addresses come from lib/net.nix, so they follow the Pis when they
  # renumber into `servers`. Until then the Pis are on the flat LAN, queries
  # leave through wan masqueraded from gate's own lease, and AdGuard sees gate
  # rather than the client. Attribution only becomes real once there is no NAT
  # between them.
  fleetResolvers = [
    net.hosts.core4.ip
    net.hosts.lifeline.ip
  ];

  # guest gets public resolvers instead. lib/net.nix calls that segment
  # internet-only, and pointing it at the fleet's resolvers would contradict
  # that and require a forward rule into servers to work at all.
  resolversFor =
    name:
    if name == "guest" then
      [
        "1.1.1.1"
        "9.9.9.9"
      ]
    else
      fleetResolvers;
in
{
  # A segment declared in lib/net.nix but not carried by an interface here
  # would have a subnet, a gateway and a pool and yet never be addressed,
  # routed, firewalled or served, and nothing would fail at evaluation. It
  # would surface as devices on that VLAN silently getting no lease.
  # modules/firewall.nix guards its own list the same way.
  assertions = [
    {
      assertion =
        lib.sort (a: b: a < b) (builtins.attrValues segmentOn)
        == lib.sort (a: b: a < b) (builtins.attrNames seg);
      message = ''
        hosts/gate/routing.nix carries segments ${
          lib.concatStringsSep ", " (lib.sort (a: b: a < b) (builtins.attrValues segmentOn))
        }, but lib/net.nix declares ${
          lib.concatStringsSep ", " (lib.sort (a: b: a < b) (builtins.attrNames seg))
        }. Every declared segment needs an interface here, or devices on it get
        no address and no route.
      '';
    }
  ];

  # nftables backend rather than iptables. The reason is filterForward below:
  # NixOS only offers a filtered forward chain on this backend, and a router
  # whose forward chain defaults to accept is not a firewall.
  networking.nftables.enable = true;

  # Masquerade every segment out of wan, and enable IPv4 forwarding. Using the
  # nat module rather than a hand-written ruleset on purpose: it is the
  # well-trodden path, and hand-rolled NAT on a box that is becoming the house
  # router is a poor place to be original.
  networking.nat = {
    enable = true;
    externalInterface = net.hosts.gate.wanIface;
    internalInterfaces = segmentIfaces;
  };

  networking = {
    # Tagged sub-interfaces on the trunk, derived from taggedSegments above.
    vlans = builtins.listToAttrs (
      map (name: {
        name = tagged name;
        value = {
          id = seg.${name}.id;
          interface = trunk;
        };
      }) taggedSegments
    );

    # Wi-Fi clients arrive tagged from the AP, the wired machine arrives
    # untagged on its own port, and both need to be on one segment for
    # discovery to work between them.
    bridges.${trustedBr}.interfaces = [
      (tagged "trusted")
      wired
    ];

    interfaces = lib.mapAttrs (_: name: {
      ipv4.addresses = [
        {
          address = seg.${name}.gateway;
          inherit (seg.${name}) prefixLength;
        }
      ];
    }) segmentOn;

    firewall = {
      # Default-drop forwarding. Without this the forward chain accepts
      # everything, and a router whose forward chain defaults to accept is not
      # a firewall.
      filterForward = true;

      # Inter-segment policy, plus one deny. The accepts below are
      # segment-to-segment, which the nat module says nothing about, and
      # everything not named is refused by the default-drop chain rather than
      # by a rule.
      #
      # The deny is the exception to all of that, and deliberately so. It is
      # segment-to-wan, the same direction nat covers, and it exists precisely
      # to take precedence over nat's blanket
      # `iifname { internalInterfaces } oifname wan accept`. `mkBefore` pins
      # that ordering: nixpkgs documents both definitions as appended to
      # `forward-allow` and declares no priority between them, so relying on
      # the observed merge order would make this silently dead code the day it
      # changed.
      #
      # iot gets DNS to the Pis and nothing else. It is on the fleet resolvers
      # so its lookups are filtered and visible in AdGuard, which is most of
      # the point of having an iot segment, but it has no business reaching
      # anything else in servers.
      extraForwardRules = lib.mkBefore ''
        iifname ${nftSet (quoted deniedUpstream)} oifname "${wan}" ip daddr ${nftSet upstreamPrivate} drop comment "only trusted reaches upstream management"
        iifname "${trustedBr}" oifname "${trunk}" accept comment "trusted reaches servers"
        iifname "${tagged "iot"}" oifname "${trunk}" meta l4proto { tcp, udp } th dport 53 accept comment "iot resolves via the Pis, nothing else"
        iifname "${tagged "work"}" oifname "${trunk}" meta l4proto { tcp, udp } th dport 53 accept comment "work resolves via the Pis, nothing else"
      '';

      # DHCP requests arrive before the client has an address, so nothing
      # address-based can cover them. Scoped per segment interface, so no DHCP
      # server is exposed on the WAN side.
      interfaces = lib.genAttrs dhcpIfaces (_: {
        allowedUDPPorts = [ 67 ];
      });
    };
  };

  # The default is sized for a desktop making a few hundred connections. A
  # router holds the state for every device in the house at once, and the
  # failure mode when the table fills is dropped connections with
  # "nf_conntrack: table full" in dmesg, which reads like a network fault
  # rather than a tuning problem.
  boot.kernel.sysctl = {
    "net.netfilter.nf_conntrack_max" = 262144;

    # Answer ARP only for addresses configured on the interface the request
    # arrived on, and source ARP requests from an address in the target's
    # subnet.
    #
    # Linux defaults to answering for *any* local address on *any* interface,
    # which is reasonable on a host and wrong on a router holding a different
    # subnet on each of four segments. It caused a real failure during the
    # cutover: the AP, sitting on servers, ARPed for 192.168.10.1, which lives
    # on br-trusted. gate answered on lan0 anyway, so the AP unicast a DHCP
    # renewal for its old address to a gateway that was not on its segment,
    # Kea matched the subnet from the client address rather than the interface,
    # and renewed a lease from the wrong segment. It then repeated that
    # indefinitely, because a successful renewal never triggers a rebind. Only
    # a power cycle broke the loop.
    #
    # arp_ignore=1 makes gate stop volunteering addresses that belong to other
    # segments. arp_announce=2 keeps its own requests from advertising one.
    "net.ipv4.conf.all.arp_ignore" = 1;
    "net.ipv4.conf.default.arp_ignore" = 1;
    "net.ipv4.conf.all.arp_announce" = 2;
    "net.ipv4.conf.default.arp_announce" = 2;
  };

  # Ordering, so the retries below are a safety net rather than the mechanism.
  # The address units are what make each interface bindable, and Kea's stock
  # ordering only reaches network-online.target, which implies nothing about
  # any particular interface being configured.
  systemd.services.kea-dhcp4-server.after = map (i: "network-addresses-${i}.service") dhcpIfaces;

  services.kea.dhcp4 = {
    enable = true;
    settings = {
      interfaces-config = {
        interfaces = dhcpIfaces;

        # Kea tries once by default and, on failure, runs with no listening
        # socket rather than exiting. Observed on the first deploy: it started
        # while lan0 was still down, logged "no interface configured to listen
        # to DHCP traffic", and stayed up and deaf.
        #
        # That is the worst shape a DHCP failure can take on a router. Nothing
        # breaks immediately, because existing leases keep working; the house
        # falls over an hour later when clients try to renew, with no event
        # anywhere near the cause.
        #
        # Retry instead, and require every configured interface, so a
        # persistent failure exits non-zero and the unit's Restart=on-failure
        # keeps trying. The cost is that deploying before the trunk is cabled
        # loops the unit, which is why the header says not to.
        service-sockets-max-retries = 5;
        service-sockets-retry-wait-time = 5000;
        service-sockets-require-all = true;

        # Kea is deliberately not bound to the trunk parent. Its raw sockets
        # would receive tagged frames as well as untagged ones, because the
        # kernel delivers to AF_PACKET taps before VLAN demux, so a request
        # from an iot device would arrive on `lan0.30` and on `lan0`, and the
        # `lan0` copy would be answered from the servers pool. Serving DHCP
        # only where a segment declares a pool, and giving servers none, means
        # nothing binds `lan0` and the ambiguity cannot arise.
      };

      # Leases survive a restart of the daemon and a reboot of the box. Without
      # persistence every reboot is a fresh pool and clients renumber, which on
      # a router is indistinguishable from a fault.
      lease-database = {
        type = "memfile";
        persist = true;
        name = "/var/lib/kea/dhcp4.leases";
      };

      valid-lifetime = 3600;
      renew-timer = 900;
      rebind-timer = 1800;

      # One subnet per segment, each pinned to the interface that carries it,
      # so a request arriving on the iot VLAN cannot be answered from the
      # trusted pool.
      subnet4 = lib.mapAttrsToList (
        iface: name:
        let
          s = seg.${name};
        in
        {
          inherit (s) id subnet;
          interface = iface;
          pools = [ { pool = "${s.pool.first} - ${s.pool.last}"; } ];
          option-data = [
            {
              name = "routers";
              data = s.gateway;
            }
            {
              name = "domain-name-servers";
              data = lib.concatStringsSep ", " (resolversFor name);
            }
          ];
        }
      ) dhcpOn;
    };
  };
}
