# Raspberry Pi 3B — pihole DNS
{ hostname, ... }:
{
  networking.hostName = hostname;

  # Static IP
  networking.interfaces.eth0.ipv4.addresses = [
    {
      address = "192.168.86.36";
      prefixLength = 24;
    }
  ];
  networking.defaultGateway = "192.168.86.1";
  networking.nameservers = [
    "1.1.1.1"
    "8.8.8.8"
  ];

  # Pihole ports — DNS, HTTP admin, DHCP
  networking.firewall.allowedTCPPorts = [
    53
    80
  ];
  networking.firewall.allowedUDPPorts = [
    53
    67
  ];
}
