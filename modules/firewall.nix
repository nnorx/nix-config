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
# sshd also binds only the addresses it is meant to be reached on (see
# modules/ssh.nix), so a rule that fails open here does not put it on the
# internet. That bind is by address, not interface: on gate's LAN side this
# module is still the only scoping there is. gate's WAN address is never bound,
# so sshd's start does not depend on a DHCP lease.
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
