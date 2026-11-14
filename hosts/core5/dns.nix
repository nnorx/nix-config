# core5's DNS: over TLS to `encryptedResolvers`, as forge's is away from home
# (hosts/forge/dns.nix), so the wire shows that core5 talks to Quad9 and not
# which names. Outside the fleet's resolvers on purpose: core5 runs the
# metrics stack that watches them and alerts when they fail, so asking them
# would make monitoring depend on what it monitors. tests/core5-dns.nix runs
# it, the UniFi containers' lookups included, in VMs.
{ net, ... }:
{
  services.resolved.enable = true;
  services.resolved.settings.Resolve = {
    DNS = map (r: "${r.ip}#${r.name}") net.encryptedResolvers;

    # Strict: where 853 is refused, lookups fail rather than go out readable.
    DNSOverTLS = true;

    # systemd's built-in fallback list is plaintext.
    FallbackDNS = [ ];

    # Home Assistant's mDNS is its own library, and neither of these.
    LLMNR = false;
    MulticastDNS = false;
  };

  # By address: TLS needs the clock, and core5's RTC loses it without power.
  networking.timeServers = net.timeServers;
}
