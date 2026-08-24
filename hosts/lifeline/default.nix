# Raspberry Pi 4 — AdGuard Home DNS + Unbound recursive resolver
#
# One of two independent DNS paths. This host resolves for itself and depends
# on no other host, as does core4, so either can serve the LAN alone. It
# replaced core3, which ran AdGuard only and forwarded to core4's Unbound —
# making core4 a single point of failure for both paths.
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
    # allowFrom is empty: nothing off-box queries this Unbound, so the module
    # binds 127.0.0.1 only and it is not on the LAN at all.
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

  # DNS + AGH web UI — LAN interface only. Unbound's port is not opened, and
  # with an empty allowFrom it is not bound to the LAN either.
  networking.firewall.interfaces.${host.iface} = {
    allowedTCPPorts = [
      53 # DNS
      net.ports.adguardWeb
    ];
    allowedUDPPorts = [ 53 ];
  };
}
