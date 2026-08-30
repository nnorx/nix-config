# Fleet network topology — single source of truth for LAN addressing.
#
# Hosts and modules read addresses from here instead of embedding literals, so
# a renumbering touches one file. Consumers reference attribute *names*, never
# values, which keeps the option open of moving this file into a private flake
# input later without editing anything that reads it.
{
  lan = {
    prefixLength = 24;
    gateway = "192.168.86.1";
  };

  # Per-host wired NIC. `iface` is the kernel name — the Pi 4 and 5 enumerate
  # their onboard NIC as end0.
  hosts = {
    core4 = {
      ip = "192.168.86.32";
      iface = "end0";
    };
    core5 = {
      ip = "192.168.86.49";
      iface = "end0";
    };

    # Second, independent DNS path. Addressed below the Nest's DHCP pool
    # (.20-.250) so the router can never lease this address to anything else,
    # unlike the core* hosts which sit inside the pool and rely on being powered
    # on to defend their addresses.
    lifeline = {
      ip = "192.168.86.11";
      iface = "end0";
    };

    # gate (CWWK N100, 4x i226) deliberately has no `ip` yet: it keeps its DHCP
    # lease from the Nest until the router subnets are settled, so pinning one
    # here would be fiction.
    #
    # The WAN port is `wanIface`, deliberately not `iface`. `iface` means "the
    # NIC hosts/common binds this host's static address and default gateway to",
    # and on a router that is a LAN port. Naming the WAN port `iface` would mean
    # that the moment gate gains an `ip`, hosts/common silently configures the
    # LAN address and the LAN default gateway on the interface facing the
    # internet. gate gets an `iface` of its own when the LAN side exists.
    #
    # Until then it has no `ip`, and nothing may assume otherwise: hosts/core5's
    # pimon firewall and modules/unbound's allowFrom both dereference
    # `net.hosts.<h>.ip` unguarded, so adding gate to `pimonAgents` or to an
    # `allowFrom` before it is addressed fails *that* host's evaluation, not
    # gate's.
    gate = {
      wanIface = "enp2s0";
    };
  };

  # Hosts running a pimon agent that report to the collector on core5. Named
  # rather than derived from `hosts`: address presence is not the same fact as
  # running an agent, and core5's firewall opens a port per entry.
  pimonAgents = [
    "core4"
    "lifeline"
  ];

  # Ports forming contracts *between* hosts, so they can't live in one module:
  # core4 and lifeline each dial their own unbound on loopback; both dial
  # core5's pimon collector; every AdGuard host opens adguardWeb on its LAN
  # interface.
  ports = {
    unbound = 5335;
    pimon = 8080;
    adguardWeb = 3000;
  };
}
