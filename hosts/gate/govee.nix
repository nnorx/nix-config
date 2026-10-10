# Govee lights on iot, driven by Home Assistant on core5 over their LAN API,
# without giving core5 an address on iot.
#
# The API is three UDP ports. Home Assistant scans by multicast to
# `net.goveeGroup` on `goveeScan`, each light answers by unicast to the
# scanner's address on `goveeReply`, and commands go to each light on
# `goveeCommand`. govee_light_local has no way to name a light by address, so
# the scan itself has to reach iot.
#
# An iot interface on core5 would do that, and was the first plan. It was
# dropped because it makes core5 a second border into iot that nothing was
# designed as: Docker publishes UniFi's ports past core5's input firewall, and
# core5 forwards packets for Docker. The host that administers the network
# would sit one hop from the least trusted devices in the house. This way gate
# stays the only place segments meet, and what crosses is the three rules at
# the bottom.
#
# The scan crosses as routed multicast. smcroute installs one static route:
# the group, from core5's address only, from servers into iot. The kernel
# forwards multicast only while its TTL is above the outgoing interface's
# threshold, 1 by default, and govee-local-api, the library Home Assistant
# uses, sends the scan with a TTL of 2 (controller.py), so one hop is what it
# allows for. Routing rather than relaying keeps core5 as the source address,
# which is where the lights send their answers.
{
  pkgs,
  net,
  ...
}:
let
  # As in ./routing.nix: the trunk, whose untagged VLAN is servers, and the iot
  # sub-interface on it.
  trunk = "lan0";
  iot = "${trunk}.${toString net.segments.iot.id}";

  homeAssistant = net.hosts.core5.ip;
  inherit (net.ports) goveeScan goveeReply goveeCommand;

  # `-N` below enables no interface by default, so only these two become
  # multicast VIFs.
  conf = pkgs.writeText "smcroute.conf" ''
    phyint ${trunk} enable
    phyint ${iot} enable
    mroute from ${trunk} source ${homeAssistant} group ${net.goveeGroup} to ${iot}
  '';

  run = "/run/smcroute";
in
{
  systemd.services.smcroute = {
    description = "Route Home Assistant's Govee scan from servers into iot";
    wantedBy = [ "multi-user.target" ];

    # smcroute resolves the interfaces once, at start. Ordered after their
    # address units, as Kea is in ./routing.nix, and restarted with the VLAN
    # device, since recreating it would leave the route on an interface index
    # that no longer exists.
    after = [
      "network-addresses-${trunk}.service"
      "network-addresses-${iot}.service"
      "${iot}-netdev.service"
    ];
    partOf = [ "${iot}-netdev.service" ];

    serviceConfig = {
      # Socket and PID file in its own runtime directory, which
      # ProtectSystem=strict leaves writable. `smcroutectl -u
      # /run/smcroute/sock show` lists the route as installed.
      ExecStart = "${pkgs.smcroute}/bin/smcrouted -n -N -f ${conf} -u ${run}/sock -P ${run}/pid";
      RuntimeDirectory = "smcroute";
      Restart = "on-failure";
      RestartSec = 5;

      # It opens a raw IGMP socket and programs the kernel's multicast routing
      # table, and needs nothing else.
      CapabilityBoundingSet = [
        "CAP_NET_ADMIN"
        "CAP_NET_RAW"
      ];
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
        "AF_UNIX"
      ];
      RestrictNamespaces = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      SystemCallArchitectures = "native";
    };
  };

  # Each direction is its own accept, with no reliance on established state.
  # The answers to a scan cannot be replies in conntrack's sense: the scan went
  # to a group address, and the answer comes from a light's own. Every rule
  # names core5's address, and the reverse-path filter is what makes a source
  # address on gate mean the segment it arrived from.
  #
  # Counted, so `nft list chain inet nixos-fw forward-allow` shows which leg
  # of the exchange is getting through.
  networking.firewall.extraForwardRules = ''
    iifname "${trunk}" oifname "${iot}" ip saddr ${homeAssistant} ip daddr ${net.goveeGroup} udp dport ${toString goveeScan} counter accept comment "govee: Home Assistant scans iot"
    iifname "${trunk}" oifname "${iot}" ip saddr ${homeAssistant} udp dport ${toString goveeCommand} counter accept comment "govee: Home Assistant commands a light"
    iifname "${iot}" oifname "${trunk}" ip daddr ${homeAssistant} udp dport ${toString goveeReply} counter accept comment "govee: a light answers Home Assistant"
  '';
}
