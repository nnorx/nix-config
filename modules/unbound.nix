# Unbound — recursive DNS resolver with DNSSEC
# Listens on localhost:5335 for queries from AdGuard Home
{ pkgs, ... }:
{
  services.unbound = {
    enable = true;
    resolveLocalQueries = false; # Pi uses AGH (port 53), not unbound directly

    settings = {
      server = {
        interface = [ "127.0.0.1" ];
        port = 5335;
        access-control = [ "127.0.0.1/32 allow" ];

        # Use current root server addresses
        root-hints = "${pkgs.dns-root-data}/root.hints";

        # DNSSEC hardening (trust anchor managed automatically by NixOS)
        harden-glue = true;
        harden-dnssec-stripped = true;
        harden-below-nxdomain = true;
        harden-algo-downgrade = true;
        harden-referral-path = true;
        use-caps-for-id = true; # Anti-spoofing via randomized query case (0x20)
        val-clean-additional = true; # Strip unvalidated data from DNSSEC responses
        aggressive-nsec = true; # Synthesize NXDOMAIN from cached NSEC (RFC 8198)
        unwanted-reply-threshold = 10000000; # Detect cache poisoning floods

        # DNS rebinding protection — refuse private IPs from upstream authoritative servers
        private-address = [
          "10.0.0.0/8"
          "172.16.0.0/12"
          "192.168.0.0/16"
          "169.254.0.0/16"
          "100.64.0.0/10"
          "::1/128"
          "fd00::/8"
          "fe80::/10"
        ];

        # Privacy
        qname-minimisation = true;
        hide-identity = true;
        hide-version = true;

        # Performance tuning for Pi 4
        num-threads = 4;
        msg-cache-size = "64m";
        rrset-cache-size = "128m";
        key-cache-size = "32m";
        prefetch = true;
        edns-buffer-size = 1232;
      };
      # No forward-zone = true recursive resolution from root servers
    };
  };
}
