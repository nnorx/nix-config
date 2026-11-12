# gate routes, for every segment in lib/net.nix. `wan` faces the modem and is
# the house's only route out, so a bad ruleset here is an outage.
#
# `lan0` is the tagged trunk to the Flex switch, with `servers` untagged on it:
# the switch and the AP must reach the controller before they know any tag.
#
# `lan1` is untagged trusted, bridged with the tagged trusted VLAN so a machine
# cabled to gate shares a broadcast domain, and mDNS discovery, with Wi-Fi.
# Bridged frames bypass the forward chain. If `br_netfilter` is ever loaded
# (container runtimes load it), they traverse it, match nothing and are
# dropped, which breaks discovery invisibly in `nft list ruleset`.
#
# Kea requires carrier on every interface it serves, so a dead trunk takes
# DHCP down loudly rather than leaving it running deaf.
#
# Lists are derived from `segmentOn` and lib/net.nix where they can be, so a
# new segment cannot be half-configured here.
{
  lib,
  net,
  ...
}:
let
  seg = net.segments;

  trunk = net.hosts.gate.trunkIface; # tagged trunk to the Flex switch; untagged = servers
  wired = net.hosts.gate.wiredIface; # untagged trusted, a dedicated run to one machine
  trustedBr = "br-trusted"; # tagged trusted + `wired`, so they share a domain
  wan = net.hosts.gate.wanIface; # bound here too, since a forward rule names it
  tunnel = net.hosts.gate.vpnIface; # WireGuard, set up in ./wireguard.nix

  # 802.1q sub-interface for a tagged segment.
  tagged = name: "${trunk}.${toString seg.${name}.id}";

  # Everything but servers, which is untagged on the trunk. `vlans` is derived
  # from this, so no segment is addressed on an interface never created.
  taggedSegments = [
    "trusted"
    "iot"
    "work"
    "guest"
  ];

  # Which segment each routed interface carries. Addresses, Kea subnets, nat
  # internals and firewall scopes are generated from this.
  segmentOn = {
    ${trustedBr} = "trusted";
    ${trunk} = "servers"; # untagged on the trunk
    ${tagged "iot"} = "iot";
    ${tagged "work"} = "work";
    ${tagged "guest"} = "guest";

    # Listed so the tunnel inherits masquerade, the upstream deny and the DNS
    # redirect. No pool, so no DHCP; ./wireguard.nix sets its address.
    ${tunnel} = "vpn";
  };

  segmentIfaces = builtins.attrNames segmentOn;

  # DHCP only where a segment declares a pool. servers declares none, which
  # keeps Kea off the trunk parent `lan0`: see `servers` in lib/net.nix.
  dhcpOn = lib.filterAttrs (_: name: seg.${name} ? pool) segmentOn;
  dhcpIfaces = builtins.attrNames dhcpOn;

  # Private space out `wan`, which is the ISP device's management interface.
  # No segment but trusted should reach the box that terminates the house's
  # internet. The deny is derived by exclusion, so a new segment is denied by
  # default, and private space is never a legitimate destination out `wan`, so
  # it stays correct if the ISP device is ever bridged.
  upstreamPrivate = [
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "169.254.0.0/16"
    "100.64.0.0/10" # CGNAT, which docs/router.md, "WAN", says how to check for
  ];
  managesUpstream = [ trustedBr ];
  deniedUpstream = lib.filter (i: !(builtins.elem i managesUpstream)) segmentIfaces;

  nftSet = xs: "{ ${lib.concatStringsSep ", " xs} }";
  quoted = map (x: "\"${x}\"");

  # Handed out directly rather than proxied by gate, so AdGuard sees each
  # client: nat masquerades only out `wan`. Named by host, so the redirect
  # knows which segment each resolver sits on.
  fleetResolverHosts = net.resolvers;

  # Filtered before dereferencing: Nix forces an assertion and the code it
  # guards in no set order, and an "attribute 'ip' missing" throw would win.
  resolverIsUsable = h: net.hosts ? ${h} && net.hosts.${h} ? ip && net.hosts.${h} ? segment;
  usableResolvers = lib.filter resolverIsUsable fleetResolverHosts;

  fleetResolvers = map (h: net.hosts.${h}.ip) usableResolvers;

  # Derived, so the redirect's exclusion follows a resolver that moves.
  resolverSegments = map (h: net.hosts.${h}.segment) usableResolvers;

  # guest is internet-only, and the fleet's resolvers would need a forward rule
  # into servers.
  publicResolverSegments = [ "guest" ];
  usesFleetResolvers = name: !(builtins.elem name publicResolverSegments);

  resolversFor = name: if usesFleetResolvers name then fleetResolvers else net.publicResolvers;

  # Catch clients with a hardcoded resolver, which would otherwise be
  # unfiltered and absent from AdGuard's log. The redirect keeps the client's
  # source only across subnets: see `servers` in lib/net.nix.
  #
  # guest is excluded: it is not on the fleet's resolvers and has no path into
  # servers. servers is excluded: it is the hairpin case, and it carries the
  # resolvers' own Unbound recursion, which a redirect would loop back onto
  # them. gate's own Unbound is safe because its traffic hits `output`, not
  # `prerouting`. A new segment is redirected by default.
  #
  # Only whole segments can be excluded, so a host that recurses itself, which
  # the redirect would leave with SERVFAIL, needs a segment of its own.
  redirectOn = lib.filterAttrs (
    _: name: usesFleetResolvers name && !(builtins.elem name resolverSegments)
  ) segmentOn;
  redirectIfaces = builtins.attrNames redirectOn;

  # DoT and DoQ (853) are refused wherever 53 is redirected, so a device that
  # falls back to plaintext lands on the redirect. Derived from `redirectOn`
  # so the two cannot drift. `dotExempt` gives a segment its 853 back where
  # refusing it breaks something, such as a managed laptop on work set to
  # require DoT; port 53 stays redirected.
  dotExempt = [ ];
  refuseDotIfaces = builtins.attrNames (
    lib.filterAttrs (_: name: !(builtins.elem name dotExempt)) redirectOn
  );

  # Spread across the resolvers so neither is a single point of failure for
  # clients DHCP cannot repoint. `numgen inc` picks per connection, so a retry
  # usually lands on the other one. That is the only failover: nftables cannot
  # health-check a target.
  resolverMap = lib.concatStringsSep ", " (lib.imap0 (i: ip: "${toString i} : ${ip}") fleetResolvers);

  # sshd's LAN addresses: the gateway of the segment each of gate's
  # `sshInterfaces` carries, so the bind follows what the interface carries
  # (see `sshInterfaces` in lib/net.nix). Filtered so an interface with no
  # segment is reported by the assertion below.
  sshIfaces = net.hosts.gate.sshInterfaces;
  sshAddresses = map (i: seg.${segmentOn.${i}}.gateway) (lib.filter (i: segmentOn ? ${i}) sshIfaces);

  # The fleet's hosts on servers, derived so a new Pi reaches the internet the
  # day it is added. UniFi's containers leave core5 from its address, behind
  # Docker's masquerade. `segment` has a default because gate has none.
  serversFleet = map (h: h.ip) (
    builtins.attrValues (
      lib.filterAttrs (_: h: h ? ip && (h.segment or null) == segmentOn.${trunk}) net.hosts
    )
  );
in
{
  # A segment with no interface here would be declared but never addressed or
  # served, and nothing else fails at evaluation. modules/firewall.nix guards
  # its own list the same way.
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
      lib/net.nix names "${h}" in `resolvers`, but net.hosts has no such host
      with both an `ip` and a `segment`. Both are dereferenced unguarded in
      hosts/gate/routing.nix, to address the DNAT and to work out which segment
      to exclude from it, so without this the failure is an "attribute
      missing" trace naming neither the list nor the host. `gate` is the likely
      mistake: lib/net.nix gives it neither, deliberately.
    '';
  }) fleetResolverHosts
  ++ [
    {
      assertion = lib.all (i: segmentOn ? ${i}) sshIfaces;
      message = ''
        lib/net.nix names ${
          lib.concatStringsSep ", " (lib.filter (i: !(segmentOn ? ${i})) sshIfaces)
        } in gate's `sshInterfaces`, but hosts/gate/routing.nix carries no
        segment on it, so there is no address for sshd to bind. The firewall
        would open port 22 there with nothing listening, which reads as a
        firewall fault. Give the interface a segment, or take it out of that
        list. `wan` is the likely mistake.
      '';
    }
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
      assertion = lib.all (name: builtins.elem name (builtins.attrValues redirectOn)) dotExempt;
      message = ''
        hosts/gate/routing.nix exempts ${toString dotExempt} from the port-853
        refusal, but only redirected segments are refused in the first place:
        ${toString (builtins.attrValues redirectOn)}. An exemption naming
        anything else does nothing, so a misspelt one would leave the segment
        it meant still refused.
      '';
    }
    {
      assertion = serversFleet != [ ];
      message = ''
        hosts/gate/routing.nix finds no host in lib/net.nix with an `ip` on
        ${segmentOn.${trunk}}, so `servers-egress` would refuse every host there
        the internet, the Pis' nightly upgrades included. It would also render
        as `ip saddr { }`, an nftables syntax error that says nothing about
        why.
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

  # NixOS offers a filtered forward chain (`filterForward`) only on nftables.
  networking.nftables.enable = true;

  # sshd on the gateway address of each SSH interface, never the WAN one. The
  # firewall still scopes by interface; modules/ssh.nix has the sysctl that
  # makes binding these safe at boot, and ./wireguard.nix adds the tunnel's.
  services.openssh.listenAddresses = map (addr: { inherit addr; }) sshAddresses;

  # Masquerade and IPv4 forwarding through the nat module, the well-trodden
  # path, rather than hand-rolled NAT on the house router.
  networking.nat = {
    enable = true;
    externalInterface = net.hosts.gate.wanIface;
    internalInterfaces = segmentIfaces;
  };

  # The DNS redirect, appended to the nat module's table as its own base chain,
  # since `pre` is generated as one string. `dstnat + 10` lets an explicit port
  # forward win over it. The counter, in `nft list chain ip nixos-nat
  # dns-redirect`, says whether it has ever matched.
  #
  # `family` is declared because the nat module sets it only under
  # `mkIf networking.nat.enable`; without it, disabling nat fails evaluation
  # with an error naming neither this file nor the cause.
  networking.nftables.tables."nixos-nat" = {
    family = "ip";
    content = ''
      chain dns-redirect {
        type nat hook prerouting priority dstnat + 10;

        iifname ${nftSet (quoted redirectIfaces)} meta l4proto { tcp, udp } th dport 53 ip daddr != ${nftSet fleetResolvers} counter dnat to numgen inc mod ${toString (builtins.length fleetResolvers)} map { ${resolverMap} } comment "catch hardcoded resolvers"
      }
    '';
  };

  # iot's way out: docs/privacy.md, "Internet for iot", has the commands.
  # `iot-wan` counts every iot attempt to open a connection out `wan`, and one
  # from `iot-trial` is dropped and counted. The set is filled by hand, so no
  # device reaches this repo, and is runtime state: any reload of the ruleset
  # empties it and zeroes the counters.
  #
  # The chain returns rather than accepts, so nat's accept stays the one way
  # out `wan` and flushing the chain undoes it without a deploy. It drops
  # rather than rejects, so firmware that retries on failure waits out its own
  # timeout. DNS is unaffected: redirected queries are accepted before the
  # jump, and queries to the Pis do not leave by `wan`.
  #
  # servers-egress lets only the fleet's hosts out `wan`. The switch, the AP
  # and the rest are dropped and counted, which does not touch managing them,
  # since the controller is on servers too. NTP is the exception, so their
  # clocks keep whatever time source the controller gives them. Firmware
  # upgrades become a deliberate step: docs/unifi.md. IPv4 only, as the house
  # has no global IPv6; the drop fails closed, so IPv6 for the Pis would need
  # an `ip6 saddr` return here.
  #
  # `family` is declared for the reason given at nixos-nat.
  networking.nftables.tables."nixos-fw" = {
    family = "inet";
    content = ''
      set iot-trial {
        type ipv4_addr
        comment "iot devices on trial without the internet, added by hand"
      }

      counter iot-wan {
        comment "iot attempts to open a connection out wan"
      }

      counter iot-trial-dropped {
        comment "attempts out wan from iot-trial, dropped"
      }

      chain iot-egress {
        counter name "iot-wan"
        ip saddr @iot-trial counter name "iot-trial-dropped" drop comment "on trial without the internet"
      }

      counter servers-wan-dropped {
        comment "attempts out wan from servers, not by the fleet's hosts, dropped"
      }

      chain servers-egress {
        ip saddr ${nftSet serversFleet} return comment "the fleet's own hosts"
        udp dport 123 return comment "time, for the switch and the AP"
        counter name "servers-wan-dropped" drop comment "only the fleet's hosts reach the internet"
      }
    '';
  };

  networking = {
    vlans = builtins.listToAttrs (
      map (name: {
        name = tagged name;
        value = {
          id = seg.${name}.id;
          interface = trunk;
        };
      }) taggedSegments
    );

    bridges.${trustedBr}.interfaces = [
      (tagged "trusted")
      wired
    ];

    # Not the tunnel: the WireGuard module creates it and its address in one
    # unit, and a second address unit would race it.
    interfaces = lib.mapAttrs (_: name: {
      ipv4.addresses = [
        {
          address = seg.${name}.gateway;
          inherit (seg.${name}) prefixLength;
        }
      ];
    }) (builtins.removeAttrs segmentOn [ tunnel ]);

    firewall = {
      # Otherwise the forward chain accepts everything.
      filterForward = true;

      # Segment-to-segment accepts, with everything unnamed refused by the
      # default-drop chain, and segment-to-wan denies, which must come ahead of
      # nat's blanket `oifname wan accept`. `mkBefore` pins that order: nixpkgs
      # declares no priority between the two definitions.
      #
      # iot reaches servers for DNS alone, so its lookups are filtered and
      # logged; Govee's LAN API with core5 is in ./govee.nix.
      #
      # 853 is refused with `reject`, so a client falls back to 53 at once
      # rather than after a timeout. TCP gets a reset, since a bare `reject`
      # sends ICMP, which some stacks retry through.
      #
      # The egress jumps come after both, so they count only what would
      # otherwise reach nat's accept.
      extraForwardRules = lib.mkBefore ''
        iifname ${nftSet (quoted deniedUpstream)} oifname "${wan}" ip daddr ${nftSet upstreamPrivate} drop comment "only trusted reaches upstream management"
        ${lib.optionalString (refuseDotIfaces != [ ]) ''
          iifname ${nftSet (quoted refuseDotIfaces)} oifname "${wan}" tcp dport 853 counter reject with tcp reset comment "refuse DoT, so clients fall back to port 53"
          iifname ${nftSet (quoted refuseDotIfaces)} oifname "${wan}" udp dport 853 counter reject comment "refuse DoQ, so clients fall back to port 53"
        ''}
        iifname "${tagged "iot"}" oifname "${wan}" jump iot-egress comment "iot's way out, counted, and refused for iot-trial"
        iifname "${trunk}" oifname "${wan}" jump servers-egress comment "servers' way out, for the fleet's hosts only"
        iifname "${trustedBr}" oifname "${trunk}" accept comment "trusted reaches servers"
        iifname "${tagged "iot"}" oifname "${trunk}" meta l4proto { tcp, udp } th dport 53 accept comment "iot resolves via the Pis, nothing else"
        iifname "${tagged "work"}" oifname "${trunk}" meta l4proto { tcp, udp } th dport 53 accept comment "work resolves via the Pis, nothing else"
      '';

      # DHCP requests arrive before the client has an address, so the port is
      # opened per segment interface, never on the WAN side.
      interfaces = lib.genAttrs dhcpIfaces (_: {
        allowedUDPPorts = [ 67 ];
      });
    };
  };

  # A router holds state for every device in the house, and a full table drops
  # connections with "nf_conntrack: table full", which reads as a network fault.
  boot.kernel.sysctl = {
    "net.netfilter.nf_conntrack_max" = 262144;

    # Answer ARP only for addresses on the interface asked, and source requests
    # from the target's subnet. Linux's default answers for any local address
    # on any port, which on a router lets a client renew a lease from the
    # wrong segment.
    "net.ipv4.conf.all.arp_ignore" = 1;
    "net.ipv4.conf.default.arp_ignore" = 1;
    "net.ipv4.conf.all.arp_announce" = 2;
    "net.ipv4.conf.default.arp_announce" = 2;
  };

  # After each interface's address unit, which is what makes it bindable:
  # Kea's stock ordering reaches only network-online.target, which implies no
  # particular interface is configured. The retries below are the safety net.
  systemd.services.kea-dhcp4-server.after = map (i: "network-addresses-${i}.service") dhcpIfaces;

  services.kea.dhcp4 = {
    enable = true;
    settings = {
      interfaces-config = {
        interfaces = dhcpIfaces;

        # Kea otherwise starts with no socket while an interface is still down,
        # stays up deaf, and the house loses DHCP an hour later at renewal.
        # Retrying and requiring every interface turns that into a failing
        # unit; the cost is a restart loop while a port has no carrier.
        service-sockets-max-retries = 5;
        service-sockets-retry-wait-time = 5000;
        service-sockets-require-all = true;
      };

      # Persisted, so a reboot does not renumber every client, which on a
      # router looks like a fault.
      lease-database = {
        type = "memfile";
        persist = true;
        name = "/var/lib/kea/dhcp4.leases";
      };

      valid-lifetime = 3600;
      renew-timer = 900;
      rebind-timer = 1800;

      # Each subnet pinned to its interface, so a request on the iot VLAN
      # cannot be answered from the trusted pool.
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
