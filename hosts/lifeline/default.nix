# Raspberry Pi 4 — AdGuard Home DNS + Unbound recursive resolver
#
# The fleet's second DNS path, and the first one that is genuinely independent:
# core3 forwards to core4's Unbound, so core4 is a single point of failure for
# both. This host resolves for itself and depends on no other host, which is
# what lets core4 be taken down without an outage. It replaces core3.
{
  hostname,
  net,
  ...
}:
let
  host = net.hosts.${hostname};
in
{
  imports = [
    (import ../../modules/adguardhome.nix {
      adminUser = "lifeline";
      adminPasswordHash = "$2b$10$PIYZjQfkXcVhUcnVZYOP7uWwWeNnbfCEmiRhGuxOUxkTbVZc1Kjiy";
      upstreamDns = [ "127.0.0.1:${toString net.ports.unbound}" ];
      fallbackDns = [
        "1.1.1.1" # Used only if local Unbound is unreachable
        "8.8.8.8"
      ];
      cacheEnabled = false; # Unbound handles caching
      dnssecEnabled = false; # Unbound handles DNSSEC
    })
    # allowFrom is empty: nothing off-box queries this Unbound, unlike core4's
    # which still serves core3. Access control stays at localhost only.
    (import ../../modules/unbound.nix { })
    (import ../../modules/pimon.nix {
      mode = "agent";
      collectorUrl = "http://${net.hosts.core5.ip}:${toString net.ports.pimon}";
    })
  ];

  networking.hostName = hostname;

  # Static IP
  networking.interfaces.${host.iface}.ipv4.addresses = [
    {
      address = host.ip;
      inherit (net.lan) prefixLength;
    }
  ];
  networking.defaultGateway = net.lan.gateway;

  # Resolve through own AGH instance
  networking.nameservers = [ "127.0.0.1" ];

  # DNS + AGH web UI — LAN interface only. Unbound's port is deliberately not
  # opened; it is reachable on localhost only.
  networking.firewall.interfaces.${host.iface} = {
    allowedTCPPorts = [
      53 # DNS
      net.ports.adguardWeb
    ];
    allowedUDPPorts = [ 53 ];
  };
}
