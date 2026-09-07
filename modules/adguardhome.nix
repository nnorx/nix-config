# AdGuard Home — DNS filtering, ad blocking, and web UI
# Parameterized for use by multiple hosts with different DNS backends
#
# The admin password hash is bcrypt, so publishing it exposes it to offline
# cracking. It lives in secrets/<hostname>.yaml (sops/age) and is spliced into
# the config at activation, reaching neither git nor the Nix store.
{
  adminUser,
  upstreamDns,
  fallbackDns ? [ ],
  # Used only to resolve the *names* of DoH/DoT upstreams, before any resolver
  # is available. Two operators rather than two addresses from one, so a single
  # provider outage does not take bootstrap with it. Not Google: keeping them
  # out of the DNS path is one of the reasons this fleet exists.
  bootstrapDns ? [
    "1.1.1.1" # Cloudflare
    "9.9.9.9" # Quad9
  ],
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
      ];
    }
  );

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

      dns = {
        bind_hosts = [ "0.0.0.0" ];
        port = 53;

        upstream_dns = upstreamDns;
        fallback_dns = fallbackDns;
        bootstrap_dns = bootstrapDns;

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
        # It used to be a whole-LAN ceiling, because a second reason applied:
        # the router proxied client DNS, so every query arrived from the gateway
        # address. That stopped being true as clients moved onto gate's Kea,
        # which hands out the Pi addresses directly, so queries now arrive with
        # the client's own source address. That is what makes AdGuard's
        # per-client logging and per-client rules work at all.
        #
        # So the number has outlived both readings it was picked under: 300 was
        # chosen as per-device, 3000 as whole-LAN (#16), and it is now neither.
        # It wants a deliberate look rather than another guess. Exceeded queries
        # are dropped rather than refused, so the symptom of setting it too low
        # is intermittent partial resolution, which reads as a network fault.
        # Port 53 is restricted to the LAN interface by the firewall either way.
        ratelimit = 3000;
      };

      filtering = {
        protection_enabled = true;
        filtering_enabled = true;
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
            {
              url = "https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt";
              name = "WindowsSpyBlocker";
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
          ];
        in
        builtins.genList (i: {
          enabled = true;
          id = i + 1;
          inherit (builtins.elemAt blocklists i) url name;
        }) (builtins.length blocklists);
    };
  };
}
