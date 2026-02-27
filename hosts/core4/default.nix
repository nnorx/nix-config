# Raspberry Pi 4 — AdGuard Home DNS + Unbound recursive resolver
{ hostname, ... }:
{
  imports = [
    (import ../../modules/adguardhome.nix {
      adminUser = "core4";
      adminPasswordHash = "$2y$05$9Zwbgek0O2t/648P09CuW.5M4DqJzDsSIMD9SiUhTxe1deiPe37UK";
      upstreamDns = [ "127.0.0.1:5335" ];
      cacheEnabled = false; # Unbound handles caching
      dnssecEnabled = false; # Unbound handles DNSSEC
    })
    ../../modules/unbound.nix
    ../../modules/docker.nix
  ];

  networking.hostName = hostname;

  # Static IP
  networking.interfaces.end0.ipv4.addresses = [
    {
      address = "192.168.86.32";
      prefixLength = 24;
    }
  ];
  networking.defaultGateway = "192.168.86.1";

  # Resolve through own AGH instance
  networking.nameservers = [ "127.0.0.1" ];

  # Argon ONE M.2 case fan + power button
  services.hardware.argonone.enable = true;

  # Docker access for this host's user
  users.users.${hostname}.extraGroups = [ "docker" ];

  # DNS + AGH web UI + Unbound (for core3) — LAN interface only
  networking.firewall.interfaces.end0 = {
    allowedTCPPorts = [
      53 # DNS
      3000 # AGH web UI
      5335 # Unbound (for core3)
    ];
    allowedUDPPorts = [
      53 # DNS
      5335 # Unbound (for core3)
    ];
  };
}
