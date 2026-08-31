# Default-deny firewall. SSH is opened per interface, never globally.
#
# It used to be `allowedTCPPorts = [ 22 ]`, which opens port 22 on every
# interface a host has. That is harmless on a Pi with one NIC and wrong on a
# router, where it means sshd is reachable from whatever the WAN port faces.
#
# Each host names its own SSH-reachable interfaces in lib/net.nix, so the set
# is reviewable in the topology file rather than implied by the absence of a
# rule. Loopback is unaffected: the base ruleset accepts it outright.
#
# sshd itself is deliberately left bound to all addresses rather than given a
# ListenAddress. gate's WAN address comes from DHCP, so pinning sshd to it
# would make the daemon's start depend on a lease, trading a firewall problem
# for a boot-ordering one. The firewall is the right layer for this.
{
  lib,
  hostname,
  net,
  ...
}:
let
  host = net.hosts.${hostname} or { };
  sshInterfaces = host.sshInterfaces or [ ];
in
{
  # A host with no declared interfaces would silently have no SSH at all, which
  # on anything without a keyboard attached means a trip to wherever it lives.
  # Fail at eval instead.
  assertions = [
    {
      assertion = sshInterfaces != [ ];
      message = ''
        No `sshInterfaces` for host "${hostname}" in lib/net.nix. Without it
        this module opens port 22 on nothing and the host becomes unreachable
        over SSH on its next deploy.
      '';
    }
  ];

  networking.firewall = {
    enable = true;

    # Nothing global. Every open port is scoped to an interface, here and in
    # the host configs.
    allowedTCPPorts = [ ];
    allowedUDPPorts = [ ];

    interfaces = lib.genAttrs sshInterfaces (_: {
      allowedTCPPorts = [ 22 ];
    });
  };
}
