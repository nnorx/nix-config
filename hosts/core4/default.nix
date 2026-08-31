# Raspberry Pi 4 — AdGuard Home DNS + Unbound recursive resolver
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
      adminUser = "core4";
      upstreamDns = [ "127.0.0.1:${toString net.ports.unbound}" ];
      fallbackDns = [
        "1.1.1.1" # Used only if local Unbound is unreachable
        "9.9.9.9" # Quad9, not Google: different operator, same redundancy
      ];
      cacheEnabled = false; # Unbound handles caching
      dnssecEnabled = false; # Unbound handles DNSSEC
    })
    # allowFrom is empty: core3 is retired and nothing off-box queries this
    # Unbound, so the module binds 127.0.0.1 only and it is not on the LAN.
    (import ../../modules/unbound.nix { })
    ../../modules/docker.nix
    (import ../../modules/pimon.nix {
      mode = "agent";
      collectorUrl = "http://${net.hosts.core5.ip}:${toString net.ports.pimon}";
    })
  ];

  # Resolve through own AGH instance
  networking.nameservers = [ "127.0.0.1" ];

  # Docker access for this host's user
  users.users.${hostname}.extraGroups = [ "docker" ];

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
