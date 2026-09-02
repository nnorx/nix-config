# gate routes, for all four segments.
#
# Still behind the Nest: `wan` keeps its DHCP lease, so this is double NAT,
# which breaks inbound and UPnP and nothing here depends on either.
#
# `lan0` is the tagged trunk to the Flex switch. `servers` is the *untagged*
# VLAN on it, deliberately: the switch and the AP have to reach the controller
# to be managed at all, and an infrastructure device that can only be reached
# over a tag it has not been configured with yet is a chicken-and-egg problem.
# Untagged also means gate's own management address stays on `lan0`, so
# `sshInterfaces` in lib/net.nix needs no change.
#
# `lan1` is untagged trusted, bridged with the tagged trusted VLAN rather than
# given a subnet of its own, so a machine cabled directly to gate shares a
# broadcast domain with the phones and laptops on Wi-Fi. Separate subnets would
# break mDNS between them, which surfaces later as printer and cast discovery
# quietly not working.
#
# **This is inert until the switch uplink physically moves to lan0.** Nothing
# is cabled to these interfaces yet.
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

  # 802.1q sub-interface for a tagged segment.
  tagged = name: "${trunk}.${toString seg.${name}.id}";

  # Every interface that carries a segment, and the segment it carries.
  # Generating the addresses, Kea subnets and firewall scopes from one list is
  # what stops a fifth segment being added in four places and forgotten in a
  # fifth.
  segmentOn = {
    ${trustedBr} = seg.trusted;
    ${trunk} = seg.servers; # untagged on the trunk
    ${tagged "iot"} = seg.iot;
    ${tagged "guest"} = seg.guest;
  };

  # Clients are handed both Pi resolvers directly rather than gate proxying to
  # them, which is what keeps AdGuard's per-client attribution meaningful.
  #
  # These addresses come from lib/net.nix, so they follow the Pis when they
  # renumber into `servers`. Until that happens the Pis are still on the flat
  # LAN, queries leave through wan and arrive masqueraded from gate's own
  # lease, and AdGuard sees gate rather than the client. Attribution only
  # becomes real once the Pis are on the other side of no NAT at all.
  resolvers = [
    net.hosts.core4.ip
    net.hosts.lifeline.ip
  ];
in
{
  # nftables backend rather than iptables. The reason is filterForward below:
  # NixOS only offers a filtered forward chain on this backend, and a router
  # whose forward chain defaults to accept is not a firewall.
  networking.nftables.enable = true;

  # Masquerade lan0 out of wan, and enable IPv4 forwarding. Using the nat
  # module rather than a hand-written ruleset on purpose: it is the
  # well-trodden path, and hand-rolled NAT on a box that is becoming the house
  # router is a poor place to be original.
  networking.nat = {
    enable = true;
    externalInterface = net.hosts.gate.wanIface;
    internalInterfaces = builtins.attrNames segmentOn;
  };

  networking = {
    # Tagged sub-interfaces on the trunk. servers is absent on purpose: it is
    # the untagged VLAN, so it is `trunk` itself.
    vlans = {
      "${tagged "trusted"}" = {
        id = seg.trusted.id;
        interface = trunk;
      };
      "${tagged "iot"}" = {
        id = seg.iot.id;
        interface = trunk;
      };
      "${tagged "guest"}" = {
        id = seg.guest.id;
        interface = trunk;
      };
    };

    # Wi-Fi clients arrive tagged from the AP, the wired machine arrives
    # untagged on its own port, and both need to be on one segment for
    # discovery to work between them.
    bridges.${trustedBr}.interfaces = [
      (tagged "trusted")
      wired
    ];

    interfaces = lib.mapAttrs (_: s: {
      ipv4.addresses = [
        {
          address = s.gateway;
          inherit (s) prefixLength;
        }
      ];
    }) segmentOn;

    firewall = {
      # Default-drop forwarding. Without this the forward chain accepts
      # everything, and a router whose forward chain defaults to accept is not
      # a firewall.
      #
      # No extraForwardRules: the nat module already emits
      # `iifname { "lan0" } oifname "wan" accept` from `internalInterfaces`
      # above, and the base ruleset accepts established and related. Adding the
      # same rule by hand duplicates it and, worse, decouples it from
      # `internalInterfaces`, so a later port added there would be silently
      # unmatched by the hand-written copy. Verified by reading the rendered
      # chain rather than assuming.
      filterForward = true;

      # trusted reaches servers: the Pis for DNS, AdGuard's UI, SSH. Everything
      # else between segments is refused by the default-drop chain rather than
      # by a rule, so iot and guest are isolated by not being mentioned. The
      # nat module supplies the segment-to-wan rules from internalInterfaces.
      extraForwardRules = ''
        iifname "${trustedBr}" oifname "${trunk}" accept comment "trusted reaches servers"
      '';

      # DHCP requests arrive before the client has an address, so nothing
      # address-based can cover them. Scoped per segment interface, so no DHCP
      # server is exposed on the WAN side.
      interfaces = lib.mapAttrs (_: _: {
        allowedUDPPorts = [ 67 ];
      }) segmentOn;
    };
  };

  # The default is sized for a desktop making a few hundred connections. A
  # router holds the state for every device in the house at once, and the
  # failure mode when the table fills is dropped connections with
  # "nf_conntrack: table full" in dmesg, which reads like a network fault
  # rather than a tuning problem.
  boot.kernel.sysctl."net.netfilter.nf_conntrack_max" = 262144;

  # Ordering, so the retries above are a safety net rather than the mechanism.
  # The address unit assigning lan0's address is what makes the interface
  # bindable, and Kea's stock ordering only reaches network-online.target.
  systemd.services.kea-dhcp4-server.after = map (i: "network-addresses-${i}.service") (
    builtins.attrNames segmentOn
  );

  services.kea.dhcp4 = {
    enable = true;
    settings = {
      interfaces-config = {
        interfaces = builtins.attrNames segmentOn;

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
        # keeps trying. Failing loudly and recovering beats running silently
        # and not.
        service-sockets-max-retries = 5;
        service-sockets-retry-wait-time = 5000;
        service-sockets-require-all = true;
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
      subnet4 = lib.mapAttrsToList (iface: s: {
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
            data = lib.concatStringsSep ", " resolvers;
          }
        ];
      }) segmentOn;
    };
  };
}
