# Default-deny firewall — SSH always allowed, per-host adds more ports
{ ... }:
{
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
    allowedUDPPorts = [ ];
  };
}
