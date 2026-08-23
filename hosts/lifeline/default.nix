# Raspberry Pi 4 — AdGuard Home DNS + Unbound recursive resolver
#
# The fleet's second DNS path, and the first one that is genuinely independent:
# core3 forwards to core4's Unbound, so core4 is a single point of failure for
# both. This host resolves for itself and depends on no other host, which is
# what lets core4 be taken down without an outage.
#
# Intended to replace core3, but that migration is not done here: core3 is still
# a live host, and core4 still opens Unbound on the LAN for it. Retiring core3
# means dropping its host dir, its net.nix and flake entries, and core4's
# allowFrom plus the unbound ports it opens.
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
      adminUser = "lifeline";
      adminPasswordHash = "$2b$10$PIYZjQfkXcVhUcnVZYOP7uWwWeNnbfCEmiRhGuxOUxkTbVZc1Kjiy";
      upstreamDns = [ "127.0.0.1:${toString net.ports.unbound}" ];
      fallbackDns = [
        "1.1.1.1" # Used only if local Unbound is unreachable
        "8.8.8.8"
      ];
      cacheEnabled = false; # Unbound handles caching
      dnssecEnabled = false; # Unbound handles DNSSEC
    })
    # allowFrom is empty: nothing off-box queries this Unbound, unlike core4's
    # which still serves core3. With no entries the module binds 127.0.0.1
    # only, so it is not on the LAN at all.
    (import ../../modules/unbound.nix { })
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
