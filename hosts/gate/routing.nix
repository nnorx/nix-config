# gate routes, for all five segments.
#
# `wan` faces the modem as of the Phase 7 cutover on 2026-09-05. This is the
# house's only route to the internet now, so a bad ruleset here is an outage
# rather than an inconvenience.
#
# `lan0` is the tagged trunk to the Flex switch. `servers` is the *untagged*
# VLAN on it, deliberately: the switch and the AP have to reach the controller
# to be managed at all, and an infrastructure device that can only be reached
# over a tag it has not been configured with yet is a chicken-and-egg problem.
#
# That choice moved the meaning of `lan0` from trusted to servers without
# changing its name, which silently repointed `sshInterfaces` in lib/net.nix at
# the segment holding vendor firmware and away from the one holding laptops.
# `br-trusted` is listed there now.
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
# **Kea requires carrier on every interface it serves.**
# `service-sockets-require-all` spans the four interfaces that have pools, so
# an unplugged trunk means Kea fails its retries, exits, and `Restart=on-failure`
# loops it indefinitely. That was a deploy-ordering hazard while the uplink was
# still on the Nest; now it is the property that makes a dead trunk take DHCP
# down loudly rather than leaving it running deaf.
#
# Lists below are derived from `segmentOn` and lib/net.nix wherever they can be,
# so a segment added to the topology cannot be half-configured here. Where one
# is written out instead, the comment says why.
{
  lib,
  net,
  ...
}:
let
  seg = net.segments;

  # Interface names, bound once each and used throughout.
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
  # The addresses come from lib/net.nix, so they followed the Pis into
  # `servers`. Attribution is real now that they are there: `networking.nat`
  # masquerades only on the way out `wan`, so a query from a client segment to
  # a Pi crosses the forward chain with its source address intact and AdGuard
  # sees the client rather than the gateway.
  #
  # Named by host rather than by address, because the redirect below has to
  # know which *segment* each resolver sits on to assert it is not the one it
  # is redirecting.
  fleetResolverHosts = [
    "core4"
    "lifeline"
  ];

  # Filtered before dereferencing, so a bad entry is reported by the assertion
  # below instead of throwing "attribute 'ip' missing" from inside a map. Nix
  # orders an assertion against the code it guards not at all: whichever is
  # forced first wins, and here the throw wins every time. Verified by putting
  # `gate` in the list, which lib/net.nix deliberately gives neither attribute:
  # without this filter the assertion never gets to speak.
  resolverIsUsable = h: net.hosts ? ${h} && net.hosts.${h} ? ip && net.hosts.${h} ? segment;
  usableResolvers = lib.filter resolverIsUsable fleetResolverHosts;

  fleetResolvers = map (h: net.hosts.${h}.ip) usableResolvers;

  # The segments those resolvers sit on. Derived rather than named, so the
  # redirect's exclusion follows the resolvers if one ever moves.
  resolverSegments = map (h: net.hosts.${h}.segment) usableResolvers;

  # guest gets public resolvers instead. lib/net.nix calls that segment
  # internet-only, and pointing it at the fleet's resolvers would contradict
  # that and require a forward rule into servers to work at all.
  publicResolverSegments = [ "guest" ];
  usesFleetResolvers = name: !(builtins.elem name publicResolverSegments);

  resolversFor =
    name:
    if usesFleetResolvers name then
      fleetResolvers
    else
      [
        "1.1.1.1"
        "9.9.9.9"
      ];

  # Where a client is told to use the fleet's resolvers, catch it doing
  # otherwise. A device with DNS hardcoded to 8.8.8.8 ignores everything Kea
  # hands it, so it is both unfiltered and absent from AdGuard's query log:
  # invisible in the one place the house would look.
  #
  # This is the rule the servers segment was created to make possible: the
  # redirect only preserves the client's source address when the resolver is on
  # a different subnet. See `servers` in lib/net.nix for the mechanism.
  #
  # Two exclusions, each for its own reason:
  #
  # `guest` is excluded because it is not on the fleet's resolvers at all, so
  # there is nothing to redirect it to: the forward chain has no path from
  # guest into servers, deliberately.
  #
  # `servers` is excluded twice over. It is the subnet the resolvers are on, so
  # it is exactly the hairpin case above. It also carries core4's and
  # lifeline's own Unbound, which recurses by talking to authoritative servers
  # on port 53 all over the internet; redirecting that would point each
  # resolver's recursion back at the resolvers and take DNS down completely
  # rather than degrade it. gate's own Unbound is safe without being named,
  # because locally generated traffic hits `output` and this chain is
  # `prerouting`.
  #
  # A segment added to lib/net.nix later is redirected by default: an
  # unfiltered segment is the condition this rule exists to remove, so a new
  # segment is covered until whoever adds it opts out.
  #
  # Known gap: the Unbound reasoning above is about recursion, so it holds for
  # any host that recurses, not just those on servers. A workstation running its
  # own validating resolver would get SERVFAIL rather than degraded service, and
  # only whole segments can be excluded here, so it would need its own segment
  # or an exception by address. Nothing in the fleet does this today.
  redirectOn = lib.filterAttrs (
    _: name: usesFleetResolvers name && !(builtins.elem name resolverSegments)
  ) segmentOn;
  redirectIfaces = builtins.attrNames redirectOn;

  # Spread across the resolvers rather than pinning one. The fleet runs two
  # deliberately independent resolvers, and sending every redirected client to
  # the first would quietly make it a single point of failure for precisely the
  # devices that cannot be repointed by DHCP. `numgen inc` is per-connection,
  # and stub resolvers randomise their source port per query, so a retry after
  # a timeout generally lands on the other resolver. That is the failover here;
  # nftables cannot health-check a target, so one resolver being down degrades
  # these clients rather than sparing them.
  resolverMap = lib.concatStringsSep ", " (lib.imap0 (i: ip: "${toString i} : ${ip}") fleetResolvers);
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
  ]
  ++ map (h: {
    assertion = resolverIsUsable h;
    message = ''
      hosts/gate/routing.nix names "${h}" as a fleet resolver, but net.hosts has
      no such host with both an `ip` and a `segment`. Both are dereferenced
      unguarded here, to address the DNAT and to work out which segment to
      exclude from it, so without this the failure is an "attribute missing"
      trace naming neither this list nor the host. `gate` is the likely
      mistake: lib/net.nix gives it neither, deliberately.
    '';
  }) fleetResolverHosts
  ++ [
    {
      assertion = fleetResolvers != [ ];
      message = ''
        hosts/gate/routing.nix has no usable fleet resolver, so the DNS redirect
        would have nothing to point at. The nftables rule would render as
        `mod 0` over an empty map, whose error message says nothing about this
        list.
      '';
    }
    {
      assertion = redirectOn != { };
      message = ''
        hosts/gate/routing.nix would redirect port 53 on no interface at all, so
        the rule catching hardcoded resolvers would not exist. Every segment is
        either on public resolvers or holds a resolver itself. This fails here
        rather than at `iifname { }`, which is an nftables syntax error whose
        message says nothing about why the set is empty.
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

  # Catch clients that ignore the resolvers Kea hands them.
  #
  # Merged into the nat module's own table rather than a private one: `content`
  # is `types.lines`, so this appends a chain beside the module's `pre`, `post`
  # and `out` instead of standing up a second table competing for the same
  # hook. It is a separate base chain because `pre` is generated as one string
  # and cannot be appended to.
  #
  # `dstnat + 10` puts it after `pre`, so an explicit port forward added later
  # wins over this blanket rule rather than racing it at equal priority.
  #
  # The counter is deliberate: `nft list chain ip nixos-nat dns-redirect` says
  # whether this has ever matched, and a counter that stays at zero is itself
  # the finding.
  #
  # `family` is declared here rather than left to the nat module. That module
  # supplies it only under `mkIf networking.nat.enable`, so without this the
  # option is defined by nothing the moment nat is turned off, and evaluation
  # fails with "the option `networking.nftables.tables.nixos-nat.family' is used
  # but not defined" — a message naming neither this file nor the cause.
  networking.nftables.tables."nixos-nat" = {
    family = "ip";
    content = ''
      chain dns-redirect {
        type nat hook prerouting priority dstnat + 10;

        iifname ${nftSet (quoted redirectIfaces)} meta l4proto { tcp, udp } th dport 53 ip daddr != ${nftSet fleetResolvers} counter dnat to numgen inc mod ${toString (builtins.length fleetResolvers)} map { ${resolverMap} } comment "catch hardcoded resolvers"
      }
    '';
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
      # everything.
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
    # subnet on each of five segments. It caused a real failure during the
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
        # keeps trying. The cost is that an interface with no carrier loops the
        # unit rather than being skipped, which is the trade the header
        # describes.
        service-sockets-max-retries = 5;
        service-sockets-retry-wait-time = 5000;
        service-sockets-require-all = true;

        # Kea is deliberately not bound to the trunk parent, where its raw
        # sockets would see tagged frames as well as untagged ones. Serving
        # DHCP only where a segment declares a pool, and giving servers none,
        # means nothing binds `lan0`. See `servers` in lib/net.nix.
      };

      # Without persistence every reboot is a fresh pool and clients renumber,
      # which on a router is indistinguishable from a fault.
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
