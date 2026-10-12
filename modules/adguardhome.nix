# AdGuard Home — DNS filtering, ad blocking, and web UI
# Parameterized for use by multiple hosts with different DNS backends
#
# The admin password hash is bcrypt, so publishing it exposes it to offline
# cracking. It lives in secrets/<hostname>.yaml (sops/age) and is spliced into
# the config at activation, reaching neither git nor the Nix store. So are the
# password and hash of the second login, which reads AdGuard's statistics for
# the metrics store (below).
{
  adminUser,
  upstreamDns,
  fallbackDns ? [ ],
  cacheEnabled ? false,
  cacheOptimistic ? cacheEnabled,
  dnssecEnabled ? false,
  upstreamTimeout ? "2s",
}:
{
  config,
  lib,
  pkgs,
  hostname,
  net,
  ...
}:
let
  cfg = config.services.adguardhome;

  # Reproduces what the upstream module writes to the store, with the real hash
  # in place of the sentinel. `http.address` mirrors the module's own injection.
  # JSON is a subset of YAML, so AdGuard parses this.
  renderedConfig = builtins.toJSON (
    cfg.settings
    // {
      http.address = "${cfg.host}:${toString cfg.port}";
      users = [
        {
          name = adminUser;
          password = config.sops.placeholder.adguard-admin-hash;
        }
      ]
      ++ lib.optional metrics {
        name = metricsUser;
        password = config.sops.placeholder.adguard-metrics-hash;
      };
    }
  );

  # AdGuard's counts for the metrics store, on the fleet's resolvers, which
  # every host running this module is. AdGuard has no metrics endpoint, so a
  # timer reads its statistics API and writes the totals where
  # node_exporter's textfile collector reads them (modules/node-exporter.nix).
  metrics = lib.elem hostname net.resolvers;
  textfileDir = "/run/fleet-metrics";

  # A login of its own, so the admin's password stays with Nick. AdGuard has
  # no read-only role: this one could change settings through the API, and
  # mutableSettings puts them back at the next start. Its password and hash
  # are a pair in sops, made together (docs/observability.md has the command).
  metricsUser = "metrics";

  # AdGuard names an upstream by address and port, adding DNS's port when the
  # configured one has none. Each is reported as the role it has here rather
  # than by address, so a query reads `upstream="fallback"`.
  withPort = u: if lib.hasInfix ":" u then u else "${u}:53";
  roles = builtins.toJSON {
    primary = map withPort upstreamDns;
    fallback = map withPort fallbackDns;
  };

  # The current hour's statistics, which AdGuard keeps as running totals that
  # start again from zero on the hour. Read as counters, rate() takes each of
  # those starts as a counter reset, so a rate over any window is right but
  # for the queries between the hour's last read and its end. Only totals are
  # read: the response also lists the busiest clients and domains, and
  # nothing here passes them on. The work segment is in none of it, since
  # AdGuard leaves that segment out of its statistics entirely.
  render = pkgs.writeText "adguard-metrics.jq" ''
    def role: . as $a
      | if ($roles.primary | index([$a])) then "primary"
        elif ($roles.fallback | index([$a])) then "fallback"
        else "other" end;

    (.top_upstreams_responses | add // {}) as $n
    | (.top_upstreams_avg_time | add // {}) as $t
    | ([$n | to_entries[] | {role: (.key | role), n: .value, s: (.value * ($t[.key] // 0))}]
       | group_by(.role) | map({key: .[0].role, value: {n: (map(.n) | add), s: (map(.s) | add)}})
       | from_entries) as $up
    | (["primary", "fallback"] + ($up | keys) | unique) as $seen
    | "# HELP fleet_adguard_up Whether AdGuard's statistics API answered.",
      "# TYPE fleet_adguard_up gauge",
      "fleet_adguard_up 1",
      "# HELP fleet_adguard_queries_total Queries AdGuard counted this hour. Starts again on the hour.",
      "# TYPE fleet_adguard_queries_total counter",
      "fleet_adguard_queries_total \(.num_dns_queries)",
      "# HELP fleet_adguard_blocked_total Queries blocked by a filter list this hour. Starts again on the hour.",
      "# TYPE fleet_adguard_blocked_total counter",
      "fleet_adguard_blocked_total \(.num_blocked_filtering)",
      "# HELP fleet_adguard_processing_seconds_total Time AdGuard spent answering this hour's queries. Starts again on the hour.",
      "# TYPE fleet_adguard_processing_seconds_total counter",
      "fleet_adguard_processing_seconds_total \(.avg_processing_time * .num_dns_queries)",
      "# HELP fleet_adguard_upstream_responses_total Answers from each upstream role this hour, cache and errors aside. Starts again on the hour.",
      "# TYPE fleet_adguard_upstream_responses_total counter",
      ($seen[] | "fleet_adguard_upstream_responses_total{upstream=\"\(.)\"} \($up[.].n // 0)"),
      "# HELP fleet_adguard_upstream_seconds_total Time spent waiting on each upstream role this hour. Starts again on the hour.",
      "# TYPE fleet_adguard_upstream_seconds_total counter",
      ($seen[] | "fleet_adguard_upstream_seconds_total{upstream=\"\(.)\"} \($up[.].s // 0)")
  '';

  # Every 30 seconds, the scrape interval. When AdGuard does not answer, or
  # answers something unreadable, only fleet_adguard_up 0 is written, so the
  # counters stop rather than drop to zero, which rate() would take as a reset.
  collect = pkgs.writeShellApplication {
    name = "adguard-metrics";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
    ];
    text = ''
      tmp=$(mktemp -p ${textfileDir})
      trap 'rm -f "$tmp"' EXIT

      url="http://127.0.0.1:${toString cfg.port}/control/stats?recent=3600000"
      if body=$(curl -sf --max-time 10 --netrc-file "$CREDENTIALS_DIRECTORY/netrc" "$url") &&
        out=$(printf %s "$body" | jq -r --argjson roles '${roles}' -f ${render}); then
        printf '%s\n' "$out" >"$tmp"
      else
        {
          echo "# HELP fleet_adguard_up Whether AdGuard's statistics API answered."
          echo '# TYPE fleet_adguard_up gauge'
          echo 'fleet_adguard_up 0'
        } >"$tmp"
      fi
      chmod 0644 "$tmp"
      mv "$tmp" ${textfileDir}/adguard.prom
    '';
  };

  # Runs as root via the "+" prefix on ExecStartPre. The stock preStart runs as
  # the service's DynamicUser, whose transient UID does not exist when sops
  # renders secrets at activation, so the template cannot be chowned to it in
  # advance. Root can always read it; matching StateDirectory's owner afterwards
  # keeps AdGuard able to write its own config back.
  installConfig = pkgs.writeShellScript "adguardhome-install-config" ''
    set -eu
    install -m 600 "${
      config.sops.templates."AdGuardHome.yaml".path
    }" "$STATE_DIRECTORY/AdGuardHome.yaml"
    chown --reference="$STATE_DIRECTORY" "$STATE_DIRECTORY/AdGuardHome.yaml"
  '';
in
{
  # Declared here, with no `sopsFile`: hosts/common sets `sops.defaultSopsFile`
  # to this host's file, which is the only place this module's secret ever lived.
  sops.secrets.adguard-admin-hash = { };
  sops.templates."AdGuardHome.yaml".content = renderedConfig;

  # Appended rather than replacing preStart: the stock preStart installs the
  # module's generated config, whose derivation runs `AdGuardHome --check-config`
  # at build time. Keeping it referenced preserves that validation, and this
  # script then overwrites the result with the sops-rendered copy.
  systemd.services.adguardhome.serviceConfig.ExecStartPre = lib.mkAfter [ "+${installConfig}" ];

  services.adguardhome = {
    enable = true;
    mutableSettings = false;
    host = "0.0.0.0";
    port = net.ports.adguardWeb;
    openFirewall = false; # Managed per-interface in host config

    settings = {
      users = [
        {
          name = adminUser;
          # Sentinel only. This is the value that lands in the world-readable
          # Nix store; the real hash replaces it at activation (renderedConfig
          # above). Well-formed bcrypt so --check-config still passes.
          password = "$2b$10$00000000000000000000000000000000000000000000000000000";
        }
      ];

      # Segments that are filtered but deliberately not recorded. The flag and
      # the reasoning both live in lib/net.nix; this turns them into AdGuard's
      # own per-client settings on every resolver that runs this module, so the
      # property survives without anyone remembering the UI.
      #
      # `ids` takes CIDR, so one entry covers the segment however its hosts are
      # addressed. Statistics are dropped alongside the log: a per-client query
      # count over time is a weaker record than the log but still a record.
      clients.persistent = lib.mapAttrsToList (name: seg: {
        inherit name;
        ids = [ seg.subnet ];
        ignore_querylog = true;
        ignore_statistics = true;
      }) (lib.filterAttrs (_: seg: !(seg.logQueries or true)) net.segments);

      # What the resolvers keep, set here rather than left to AdGuard's
      # defaults (90 days of log, a day of statistics), so the retention is a
      # decision that shows up in review. docs/privacy.md, "What the resolvers
      # keep", has the reasoning.
      #
      # The log exists to debug a device: what it looked up and what was
      # blocked when it misbehaved. `interval` is a rotation period, not an
      # age limit. AdGuard renames the log aside once its oldest entry passes
      # the interval and deletes the previous one, so entries live between one
      # and two intervals. 84h therefore keeps at least three and a half days,
      # which covers a fault noticed after a weekend, and never more than a
      # week.
      querylog = {
        enabled = true;
        file_enabled = true;
        interval = "84h";
      };

      # Per-client and per-domain counts behind the dashboard. Its limit is a
      # true age limit, in hourly buckets. A day is AdGuard's default and
      # enough to see which device is busy; the log answers anything older.
      statistics = {
        enabled = true;
        interval = "24h";
      };

      # Debug logging writes per-query lines, client addresses among them, to
      # the journal, outside both the retention above and the work segment's
      # rule.
      # Off is the default; it is written down so turning it on is a visible
      # change rather than a flag left behind after a debugging session.
      log.verbose = false;

      dns = {
        bind_hosts = [ "0.0.0.0" ];
        port = 53;

        upstream_dns = upstreamDns;
        fallback_dns = fallbackDns;
        # Used only to resolve the *names* of DoH/DoT upstreams, before any
        # resolver is available.
        bootstrap_dns = net.publicResolvers;

        # Off, deliberately, and it has to stay off while any segment sets
        # `logQueries = false`. AdGuard zeroes the last two octets of an IPv4
        # client, and the third octet is the segment, so every client in the
        # house would be logged under one address: not even the segment
        # survives. It also anonymises before it looks the client up, so the
        # work segment's rule, which matches that segment's subnet, would stop
        # matching and work's queries would be logged. What remained would be
        # the domains, which are the
        # sensitive half, with the one thing that makes them useful for
        # debugging, and for checking that gate's dns-redirect catches a
        # device, removed. Short retention is the privacy control instead.
        anonymize_client_ip = false;

        # No client subnet is added to what AdGuard sends upstream. The
        # default; written down because the fallback below is a public
        # resolver, which would receive it.
        edns_client_subnet = {
          enabled = false;
          use_custom = false;
        };

        cache_enabled = cacheEnabled;
        # Answer from cache immediately and refresh behind it, so an upstream
        # outage is invisible for anything already looked up once.
        cache_optimistic = cacheOptimistic;
        enable_dnssec = dnssecEnabled;

        # Default is 10s. That is how long AdGuard sits on a dead upstream
        # before it will try fallback_dns, which turns a working failover into
        # a 10-20s stall on every cache miss. Only reached when an upstream
        # stops answering without refusing the connection: a powered-off host
        # or a hung resolver, both of which drop packets rather than reset.
        upstream_timeout = upstreamTimeout;

        # Queries/sec ceiling, and it is per *segment*: AdGuard buckets clients
        # by subnet (ratelimit_subnet_len_ipv4 defaults to 24, and every segment
        # is a /24), so all of trusted shares one bucket and all of iot shares
        # another. No setting makes it per-device.
        #
        # This number was picked back when the router proxied client DNS and
        # every query arrived from the gateway address, so it is not sized for
        # what it now measures and wants a deliberate look. Exceeded queries are
        # dropped rather than refused, so setting it too low shows up as
        # intermittent partial resolution, which reads as a network fault.
        ratelimit = 3000;
      };

      filtering = {
        protection_enabled = true;
        filtering_enabled = true;
        # Both are lookup services that send a hash prefix of each name to
        # AdGuard's servers. Off by default; the blocklists cover malware and
        # phishing locally.
        safebrowsing_enabled = false;
        parental_enabled = false;
        safe_search = {
          enabled = false;
        };
      };

      # Blocklists migrated from pihole gravity.db
      filters =
        let
          blocklists = [
            # Ad blocking
            {
              url = "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts";
              name = "StevenBlack Unified";
            }
            {
              url = "https://raw.githubusercontent.com/PolishFiltersTeam/KADhosts/master/KADhosts.txt";
              name = "KADhosts";
            }
            {
              url = "https://v.firebog.net/hosts/static/w3kbl.txt";
              name = "Firebog w3kbl";
            }
            {
              url = "https://v.firebog.net/hosts/AdguardDNS.txt";
              name = "Firebog AdGuard DNS";
            }
            {
              url = "https://v.firebog.net/hosts/Admiral.txt";
              name = "Firebog Admiral";
            }
            {
              url = "https://raw.githubusercontent.com/anudeepND/blacklist/master/adservers.txt";
              name = "anudeepND adservers";
            }
            {
              url = "https://v.firebog.net/hosts/Easylist.txt";
              name = "Firebog Easylist";
            }
            {
              url = "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext";
              name = "Peter Lowe adservers";
            }
            {
              url = "https://raw.githubusercontent.com/bigdargon/hostsVN/master/hosts";
              name = "hostsVN";
            }
            # Privacy / tracking
            {
              url = "https://v.firebog.net/hosts/Easyprivacy.txt";
              name = "Firebog Easyprivacy";
            }
            {
              url = "https://v.firebog.net/hosts/Prigent-Ads.txt";
              name = "Firebog Prigent Ads";
            }
            # Windows and Office telemetry, for the PC WSL runs on, and
            # Microsoft's apps on any machine. It replaces WindowsSpyBlocker's
            # spy.txt, unchanged since 2022, in the same slot, so until the
            # first refresh this id serves the old list's cached file rather
            # than another list's (see the note on ids below). Adblock syntax:
            # each rule also blocks its subdomains, the whole of
            # events.data.microsoft.com among them. Applies to work as well.
            # docs/privacy.md, "Telemetry coverage".
            {
              url = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/native.winoffice.txt";
              name = "HaGeZi Native Tracker: Microsoft";
            }
            {
              url = "https://hostfiles.frogeye.fr/firstparty-trackers-hosts.txt";
              name = "Frogeye first-party trackers";
            }
            # Malware / phishing
            {
              url = "https://raw.githubusercontent.com/DandelionSprout/adfilt/master/Alternate%20versions%20Anti-Malware%20List/AntiMalwareHosts.txt";
              name = "DandelionSprout Anti-Malware";
            }
            {
              url = "https://v.firebog.net/hosts/Prigent-Crypto.txt";
              name = "Firebog Prigent Crypto";
            }
            {
              url = "https://phishing.army/download/phishing_army_blocklist_extended.txt";
              name = "Phishing Army";
            }
            {
              url = "https://v.firebog.net/hosts/RPiList-Malware.txt";
              name = "Firebog RPiList Malware";
            }
            {
              url = "https://v.firebog.net/hosts/RPiList-Phishing.txt";
              name = "Firebog RPiList Phishing";
            }
            {
              url = "https://raw.githubusercontent.com/Spam404/lists/master/main-blacklist.txt";
              name = "Spam404";
            }
            {
              url = "https://raw.githubusercontent.com/AssoEchap/stalkerware-indicators/master/generated/hosts";
              name = "Stalkerware Indicators";
            }
            {
              url = "https://urlhaus.abuse.ch/downloads/hostfile/";
              name = "URLhaus";
            }
            {
              url = "https://lists.cyberhost.uk/malware.txt";
              name = "CyberHost Malware";
            }
            {
              url = "https://gitlab.com/quidsup/notrack-blocklists/-/raw/master/notrack-malware.txt";
              name = "NoTrack Malware";
            }
            # Device telemetry, listed last for the reason below.
            #
            # Apple's OS and app analytics, for the iPhones on trusted and the
            # work Mac. The Android phones there have no counterpart: HaGeZi's
            # lists are per handset vendor, and none covers Google's own.
            {
              url = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/native.apple.txt";
              name = "HaGeZi Native Tracker: Apple";
            }
          ];
        in
        # A list's id is its position, and AdGuard keeps each download as
        # filters/<id>.txt and serves that file until it is a day old
        # (internal/filtering/filter.go). Inserting a list moves every id after
        # it, and each would serve its neighbour's rules under its own name for
        # up to a day. Add new lists at the end.
        builtins.genList (i: {
          enabled = true;
          id = i + 1;
          inherit (builtins.elemAt blocklists i) url name;
        }) (builtins.length blocklists);
    };
  };

  # AdGuard's counts for the metrics store, read as node_exporter's user, as
  # host-status's facts are, into the same directory. The password reaches the
  # unit as a systemd credential, so the rendered file stays root's, and
  # node_exporter, on the same user, cannot read it there.
  sops.secrets.adguard-metrics-password = lib.mkIf metrics { };
  sops.secrets.adguard-metrics-hash = lib.mkIf metrics { };
  sops.templates."adguard-metrics.netrc" = lib.mkIf metrics {
    content = ''
      machine 127.0.0.1 login ${metricsUser} password ${config.sops.placeholder.adguard-metrics-password}
    '';
  };

  systemd.services.adguard-metrics = lib.mkIf metrics {
    description = "Write AdGuard's query counts for node_exporter";
    serviceConfig = import ../lib/hardening.nix // {
      Type = "oneshot";
      ExecStart = lib.getExe collect;
      User = config.services.prometheus.exporters.node.user;
      LoadCredential = [ "netrc:${config.sops.templates."adguard-metrics.netrc".path}" ];
      RuntimeDirectory = baseNameOf textfileDir;
      RuntimeDirectoryMode = "0755";
      RuntimeDirectoryPreserve = true;
      # Every 30 seconds, systemd's own "Starting" and "Finished" lines would
      # be thousands a day. A failed run still logs at notice and above.
      LogLevelMax = "notice";
    };
  };
  systemd.timers.adguard-metrics = lib.mkIf metrics {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = 0;
      OnUnitActiveSec = "30s";
      AccuracySec = "1s";
    };
  };
}
