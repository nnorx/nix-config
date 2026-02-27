# Raspberry Pi 4 — AdGuard Home DNS + Unbound recursive resolver
{ hostname, ... }:
{
  imports = [
    ../../modules/adguardhome.nix
    ../../modules/unbound.nix
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

  # DNS + AGH web UI ports — LAN interface only
  networking.firewall.interfaces.end0 = {
    allowedTCPPorts = [
      53 # DNS
      3000 # AGH web UI
    ];
    allowedUDPPorts = [ 53 ];
  };
}
