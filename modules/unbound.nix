# Unbound, the recursive resolver with DNSSEC. It and its control socket are
# on loopback only, on every host that runs it, so the resolver is absent from
# the network rather than merely refusing it.
{
  # net.ports.unbound (5335) by default, where AdGuard forwards. gate runs no
  # AdGuard and resolv.conf cannot name a port, so it listens on 53.
  port ? null,

  # False on the Pis, which resolve through their AdGuard; true on gate.
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

  dumpCache = pkgs.writeShellScript "unbound-dump-cache" ''
    export PATH="${pkgs.coreutils}/bin:$PATH"
    tmp=${cacheFile}.tmp
    if ${ctl} dump_cache > "$tmp" 2>/dev/null; then
      mv "$tmp" ${cacheFile}
    else
      rm -f "$tmp"
    fi
  '';

  # The dump is deleted once loaded: it records every name the house resolved
  # over up to four days, the work segment's included, and exists only to
  # bridge a restart. The cost is a cold cache after a crash.
  loadCache = pkgs.writeShellScript "unbound-load-cache" ''
    export PATH="${pkgs.coreutils}/bin:$PATH"
    [ -s ${cacheFile} ] || exit 0
    n=0
    while [ "$n" -lt 10 ]; do
      if ${ctl} status >/dev/null 2>&1; then
        ${ctl} load_cache < ${cacheFile} >/dev/null 2>&1 || true
        rm -f ${cacheFile}
        exit 0
      fi
      n=$((n + 1))
      sleep 1
    done
    exit 0
  '';

  # The exporter runs on the fleet's resolvers alone, not on gate.
  metrics = lib.elem hostname net.resolvers;
  host = net.hosts.${hostname};
  collector = net.hosts.${net.metricsCollector};
  probeZone = lib.last (lib.splitString "." net.resolverProbe);
in
{
  services.unbound = {
    enable = true;
    inherit resolveLocalQueries;

    localControlSocketPath = "/run/unbound/unbound.ctl";

    settings = {
      server = {
        interface = [ "127.0.0.1" ];
        port = listenPort;

        # The network has no global IPv6 route, so recursion is IPv4 only.
        do-ip6 = false;

        access-control = [ "127.0.0.1/32 allow" ];

        root-hints = "${pkgs.dns-root-data}/root.hints";

        # NixOS manages the trust anchor.
        harden-glue = true;
        harden-dnssec-stripped = true;
        harden-below-nxdomain = true;
        harden-algo-downgrade = true;
        use-caps-for-id = true; # Anti-spoofing via randomized query case (0x20)
        val-clean-additional = true; # Strip unvalidated data from DNSSEC responses
        aggressive-nsec = true; # Synthesize NXDOMAIN from cached NSEC (RFC 8198)
        unwanted-reply-threshold = 10000000; # Detect cache poisoning floods

        # DNS rebinding protection: refuse private addresses from upstream.
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

        qname-minimisation = true;
        hide-identity = true;
        hide-version = true;

        # No EDNS Client Subnet goes upstream: that needs the subnetcache
        # module, and nothing sets it.

        # Suffixes that exist only inside the house, answered NXDOMAIN here so
        # the root servers never see a device's hostname. `local` is mDNS's,
        # `internal` is reserved, and ICANN will not delegate `home` or `corp`.
        # Unbound's defaults cover home.arpa, test, invalid, localhost and the
        # private reverse zones. The list matches the local names in
        # scripts/dns-top-domains.jq. Single-label names cannot be a suffix,
        # so the root-zone copy below answers those.
        local-zone = map (zone: ''"${zone}." static'') [
          "lan"
          "local"
          "localdomain"
          "internal"
          "home"
          "corp"
        ];

        # Off, as by default, and written down because it keeps the work
        # segment unrecorded here too, where AdGuard's per-client rule cannot
        # reach.
        log-queries = false;
        log-replies = false;
        log-local-actions = false;

        # For the exporter: counters, with no client and no name in them.
        extended-statistics = lib.mkIf metrics true;

        # Sized for a Pi 4; gate takes the same values.
        num-threads = 4;
        msg-cache-size = "64m";
        rrset-cache-size = "128m";
        key-cache-size = "32m";

        cache-min-ttl = 300; # Floor short-TTL (CDN/ad/tracking) records at 5 min to cut churn
        cache-max-ttl = 259200; # Let long-TTL records survive up to 3 days, not just 1

        prefetch = true;
        prefetch-key = true; # Fetch DNSSEC keys ahead of need — trims cold-lookup latency
        serve-expired = true;
        serve-expired-ttl = 86400; # Serve stale entries up to 1 day past expiry
        serve-expired-client-timeout = 0; # Return stale immediately, refresh in background (no stall)
        edns-buffer-size = 1232;
      };

      # A local copy of the root zone (RFC 8806), so a name under a TLD that
      # does not exist, a single-label one above all, is answered here rather
      # than asked of the root servers.
      #
      # for-upstream without for-downstream: the copy stands in for the root
      # servers during recursion, and its answers go through the validator.
      # fallback-enabled asks the root servers whenever the copy is missing,
      # expired or bad. zonemd-check refuses a truncated, altered or
      # ZONEMD-stripped zone, and the file keeps the last good one.
      #
      # The file is in the StateDirectory, so a restart starts from the last
      # copy. It is about 2 MB, rewritten about twice a day: under 2 GB a year
      # on an SD card. Transfers go out TCP 53 to net.rootZoneSources, which
      # gate's servers-egress passes and its DNS redirect leaves alone.
      # tests/unbound-root-zone.nix covers it.
      auth-zone = [
        {
          name = ''"."'';
          primary = net.rootZoneSources;
          zonefile = "${config.services.unbound.stateDir}/root.zone";
          for-downstream = false;
          for-upstream = true;
          fallback-enabled = true;
          zonemd-check = true;
          zonemd-reject-absence = true;
        }
      ];
    };
  };

  # On a cold boot AdGuard's blocklist fetch, which resolves through this
  # Unbound, would fail and not retry for 24 hours, serving unfiltered DNS
  # meanwhile. Ordering suffices because Unbound is Type=notify and
  # ExecStartPost polls until it answers. `wants` is weak on purpose: if
  # Unbound fails, AdGuard still starts on its fallback_dns.
  systemd.services.adguardhome = lib.mkIf config.services.adguardhome.enable {
    after = [ "unbound.service" ];
    wants = [ "unbound.service" ];
  };

  systemd.services.unbound = {
    # Not load-bearing, but dropping it would restart Unbound on three hosts
    # for nothing.
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    # The cache persists across restarts, since a cold recursive resolver is
    # slow in a way people notice after every reboot.
    serviceConfig = {
      ExecStop = dumpCache;
      ExecStartPost = loadCache;
    };
  };

  # Totals for core5 to scrape, none naming a client or a domain. The exporter
  # reads the control socket as Unbound's user, as nixpkgs sets it up, and
  # that socket answers every unbound-control command. It asks with
  # stats_noreset, so a scrape never resets the counters.
  services.prometheus.exporters.unbound = lib.mkIf metrics {
    enable = true;
    # The host's address alone, as for node_exporter.
    listenAddress = host.ip;
    port = net.ports.unboundExporter;
    unbound = {
      host = "unix://${config.services.unbound.localControlSocketPath}";
      ca = null;
      certificate = null;
      key = null;
    };
  };

  # core5's probe must be answered from a static local zone, needing neither
  # the WAN nor the root servers (modules/blackbox.nix).
  assertions = lib.mkIf metrics [
    {
      assertion = lib.elem ''"${probeZone}." static'' config.services.unbound.settings.server.local-zone;
      message = ''
        net.resolverProbe is ${net.resolverProbe}, but modules/unbound.nix has no
        static local zone "${probeZone}". core5's probe would be recursed to the
        root servers, every 30 seconds, and fail without the WAN.
      '';
    }
  ];

  # From the collector alone, on the LAN interface.
  networking.firewall.extraCommands = lib.mkIf metrics ''
    iptables -A nixos-fw -i ${host.iface} -p tcp --dport ${toString net.ports.unboundExporter} -s ${collector.ip} -j nixos-fw-accept
  '';
}
