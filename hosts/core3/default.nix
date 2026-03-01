# Raspberry Pi 3B — AdGuard Home DNS (forwards to core4's Unbound)
{ hostname, ... }:
{
  imports = [
    (import ../../modules/adguardhome.nix {
      adminUser = "core3";
      adminPasswordHash = "$2y$05$9Zwbgek0O2t/648P09CuW.5M4DqJzDsSIMD9SiUhTxe1deiPe37UK";
      upstreamDns = [
        "192.168.86.32:5335" # core4's Unbound
      ];
      fallbackDns = [
        "1.1.1.1" # Used only if core4's Unbound is unreachable
        "8.8.8.8"
      ];
      cacheEnabled = true; # No local Unbound, AGH handles caching
      dnssecEnabled = true; # No local Unbound, AGH handles DNSSEC
    })
  ];

  networking.hostName = hostname;

  # Static IP
  networking.interfaces.eth0.ipv4.addresses = [
    {
      address = "192.168.86.36";
      prefixLength = 24;
    }
  ];
  networking.defaultGateway = "192.168.86.1";

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
  networking.firewall.interfaces.eth0 = {
    allowedTCPPorts = [
      53 # DNS
      3000 # AGH web UI
    ];
    allowedUDPPorts = [ 53 ];
  };
}
