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
