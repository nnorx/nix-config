# Raspberry Pi 3B — AdGuard Home DNS (forwards to core4's Unbound)
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
      adminUser = "core3";
      upstreamDns = [
        "${net.hosts.core4.ip}:${toString net.ports.unbound}" # core4's Unbound
      ];
      fallbackDns = [
        "1.1.1.1" # Used only if core4's Unbound is unreachable
        "8.8.8.8"
      ];
      cacheEnabled = true; # No local Unbound, AGH handles caching
      dnssecEnabled = true; # No local Unbound, AGH handles DNSSEC
    })
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

  # Swap — 1GB RAM is tight for nix-rebuild and AGH
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 1024;
    }
  ];

  # Resolve through own AGH instance
  networking.nameservers = [ "127.0.0.1" ];

  # DNS + AGH web UI ports — LAN interface only
  networking.firewall.interfaces.${host.iface} = {
    allowedTCPPorts = [
      53 # DNS
      net.ports.adguardWeb
    ];
    allowedUDPPorts = [ 53 ];
  };
}
