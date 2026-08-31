# Unbound — recursive DNS resolver with DNSSEC
# Listens on localhost and the host's LAN address for queries from AdGuard Home
{
  allowFrom ? [ ], # Host names (from lib/net.nix) permitted to query over the LAN

  # Listening port. Defaults to net.ports.unbound (5335), which is where the
  # AdGuard hosts forward and deliberately not 53, since AdGuard owns that.
  # gate has no AdGuard and has to be its own resolver, and resolv.conf cannot
  # express a port, so it listens on 53.
  port ? null,

  # Whether this host's own resolv.conf points at unbound. False on the Pis,
  # which resolve through their AdGuard on 53. True on gate, which is the
  # point of running it there.
  resolveLocalQueries ? false,
}:
{
  pkgs,
  lib,
  config,
  hostname,
  net,
  ...
}:
let
  listenPort = if port == null then net.ports.unbound else port;

  ctl = "${config.services.unbound.package}/bin/unbound-control";
  cacheFile = "/var/lib/unbound/cache.dump"; # inside unbound's StateDirectory (sandbox-writable)

  # Dump on stop — runs while the daemon is still alive; atomic via tmp + mv.
  dumpCache = pkgs.writeShellScript "unbound-dump-cache" ''
    export PATH="${pkgs.coreutils}/bin:$PATH"
    tmp=${cacheFile}.tmp
    if ${ctl} dump_cache > "$tmp" 2>/dev/null; then
      mv "$tmp" ${cacheFile}
    else
      rm -f "$tmp"
    fi
  '';

  # Load on start — wait for the control socket, then restore. Never fails the unit.
  loadCache = pkgs.writeShellScript "unbound-load-cache" ''
    export PATH="${pkgs.coreutils}/bin:$PATH"
    [ -s ${cacheFile} ] || exit 0
    n=0
    while [ "$n" -lt 10 ]; do
      if ${ctl} status >/dev/null 2>&1; then
        ${ctl} load_cache < ${cacheFile} >/dev/null 2>&1 || true
        exit 0
      fi
      n=$((n + 1))
      sleep 1
    done
    exit 0
  '';
in
{
  services.unbound = {
    enable = true;
    inherit resolveLocalQueries;

    # Local control socket for cache dump/load across reboots (see systemd units below)
    localControlSocketPath = "/run/unbound/unbound.ctl";

    settings = {
      server = {
        # Bind the LAN address only when another host actually forwards here.
        # With allowFrom empty the resolver is absent from the network rather
        # than merely refusing it, so it does not depend on the firewall or on
        # access-control to stay unreachable.
        interface = [
          "127.0.0.1"
        ]
        ++ lib.optional (allowFrom != [ ]) net.hosts.${hostname}.ip;
        port = listenPort;

        # Recurse over IPv4 only. This network gets IPv6 via ULA + RA but has no
        # global v6 prefix / default route from the Nest, so AAAA-glue upstreams
        # are unreachable and every query would dead-end in SERVFAIL. Pinning to
        # IPv4 makes the resolver immune to the v6 uplink flapping.
        do-ip6 = false;

        access-control = [
          "127.0.0.1/32 allow"
        ]
        ++ map (h: "${net.hosts.${h}.ip}/32 allow") allowFrom;

        # Use current root server addresses
        root-hints = "${pkgs.dns-root-data}/root.hints";

        # DNSSEC hardening (trust anchor managed automatically by NixOS)
        harden-glue = true;
        harden-dnssec-stripped = true;
        harden-below-nxdomain = true;
        harden-algo-downgrade = true;
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

        # Cache retention — keep entries useful longer than their raw TTLs
        cache-min-ttl = 300; # Floor short-TTL (CDN/ad/tracking) records at 5 min to cut churn
        cache-max-ttl = 259200; # Let long-TTL records survive up to 3 days, not just 1

        prefetch = true;
        prefetch-key = true; # Fetch DNSSEC keys ahead of need — trims cold-lookup latency
        serve-expired = true;
        serve-expired-ttl = 86400; # Serve stale entries up to 1 day past expiry
        serve-expired-client-timeout = 0; # Return stale immediately, refresh in background (no stall)
        edns-buffer-size = 1232;
      };
      # No forward-zone = true recursive resolution from root servers
    };
  };

  # AdGuard Home fetches its blocklists at startup and resolves those URLs
  # through this Unbound. Both units are wanted by multi-user.target, so on a
  # cold boot they start in parallel and AdGuard usually wins: every list fails
  # with "connection refused" on 127.0.0.1:5335, and it does not retry until the
  # next scheduled update, 24h later. The filter-fetch path does not fall back
  # to bootstrap_dns, so the host serves unfiltered DNS in the meantime.
  #
  # Ordering is enough because unbound is Type=notify and its ExecStartPost
  # polls unbound-control until the daemon answers, so "started" really does
  # mean "listening". `wants` is deliberately weak: if unbound fails outright,
  # AdGuard still starts and falls back to fallback_dns rather than being held
  # down with it.
  systemd.services.adguardhome = lib.mkIf config.services.adguardhome.enable {
    after = [ "unbound.service" ];
    wants = [ "unbound.service" ];
  };

  systemd.services.unbound = {
    # Don't start until the LAN address exists — unbound binds the host's LAN
    # address directly, so starting before the interface is up leaves a
    # half-bound socket.
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    # Persist the resolver cache across restarts/reboots. Unbound's cache is
    # in-memory, so the ~biweekly autoUpgrade kernel reboot would otherwise start
    # cold. Dump on stop (daemon still alive), restore on start.
    serviceConfig = {
      ExecStop = dumpCache;
      ExecStartPost = loadCache;
    };
  };
}
