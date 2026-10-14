# A fleet resolver: AdGuard Home in front of the host's own Unbound.
#
# hosts/common imports this on every host lib/net.nix lists in `resolvers`, so
# the list DHCP hands out, gate redirects stray DNS to and core5 scrapes and
# probes is also what runs the services. A host cannot be handed out as a
# resolver without running one, and the resolvers cannot drift apart, since
# they share this one body. What is a resolver's own, its header comment
# above all, stays in hosts/<name>.
{
  lib,
  hostname,
  net,
  ...
}:
let
  host = net.hosts.${hostname};
in
{
  imports = [
    (import ../../modules/adguardhome.nix { adminUser = hostname; })
    (import ../../modules/unbound.nix { })
    (import ../../modules/pimon.nix {
      mode = "agent";
      collectorUrl = "http://${net.hosts.core5.ip}:${toString net.ports.pimon}";
    })
  ];

  # Resolve through own AGH instance
  networking.nameservers = [ "127.0.0.1" ];

  # DNS and AdGuard's web UI, on the LAN interface only. Unbound's port is not
  # opened, and it binds loopback alone (modules/unbound.nix).
  networking.firewall.interfaces.${host.iface} = {
    allowedTCPPorts = [
      53 # DNS
      net.ports.adguardWeb
    ];
    allowedUDPPorts = [ 53 ];
  };

  # The pimon agent rides along because the resolvers are, today, every host
  # in net.pimonAgents. core5's collector opens a port per entry in that list,
  # not this one, and an agent missing from it posts into a dropped port that
  # Restart=always hides (hosts/core5).
  assertions = [
    {
      assertion = lib.elem hostname net.pimonAgents;
      message = ''
        ${hostname} is in net.resolvers, so hosts/common/resolver.nix runs a
        pimon agent on it, but it is not in net.pimonAgents. core5 would drop
        its reports. Add it there, or move the agent out of resolver.nix.
      '';
    }
  ];
}
