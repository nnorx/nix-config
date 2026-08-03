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
        "8.8.8.8"
      ];
      cacheEnabled = false; # Unbound handles caching
      dnssecEnabled = false; # Unbound handles DNSSEC
    })
    (import ../../modules/unbound.nix {
      allowFrom = [ "core3" ]; # Only core3 forwards DNS here
    })
    ../../modules/docker.nix
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

  # Argon ONE M.2 case fan + power button
  services.hardware.argonone.enable = true;

  # Docker access for this host's user
  users.users.${hostname}.extraGroups = [ "docker" ];

  # DNS + AGH web UI + Unbound (for core3) — LAN interface only
  networking.firewall.interfaces.${host.iface} = {
    allowedTCPPorts = [
      53 # DNS
      net.ports.adguardWeb
      net.ports.unbound # for core3
    ];
    allowedUDPPorts = [
      53 # DNS
      net.ports.unbound # for core3
    ];
  };
}
