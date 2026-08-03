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

  # Per-host wired NIC. `iface` is the kernel name — the Pi 3B enumerates its
  # onboard NIC as eth0, the Pi 4 and 5 as end0.
  hosts = {
    core3 = {
      ip = "192.168.86.36";
      iface = "eth0";
    };
    core4 = {
      ip = "192.168.86.32";
      iface = "end0";
    };
    core5 = {
      ip = "192.168.86.49";
      iface = "end0";
    };
  };

  # Ports forming contracts *between* hosts, so they can't live in one module:
  # core3 dials core4's unbound, core3/core4 dial core5's pimon collector.
  ports = {
    unbound = 5335;
    pimon = 8080;
    adguardWeb = 3000;
  };
}
