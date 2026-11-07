# The fleet's metrics store and dashboards, on the collector: VictoriaMetrics
# scraping node_exporter on every host in net.metricsTargets, Unbound's exporter
# on each resolver, Kea's on gate and the probes in ./blackbox.nix, and Grafana
# in front of it, with the dashboards in ./dashboards.nix. The alerts over it
# are in ./alerting.nix. A host's drives join from ./smartctl.nix, which the
# host imports with their names.
# docs/observability.md has the decisions and their reasons; this file has only
# what implementing them needed.
#
# State is VictoriaMetrics' data and Grafana's database, both under /var/lib,
# which on core5 is the NVMe root. Neither is backed up: Grafana's dashboards
# and datasource are provisioned from this repo, so losing either costs history,
# not configuration.
{
  config,
  lib,
  pkgs,
  hostname,
  net,
  unstable,
  ...
}:
let
  host = net.hosts.${hostname};
  hardening = import ../lib/hardening.nix;
  # The store itself, which Grafana, vmalert (./alerting.nix) and its own
  # scrape use, and vmauth in front of it at the port queries have always
  # used, below.
  storeAddress = "127.0.0.1:${toString net.ports.victoriaMetricsStore}";
  vmauthAddress = "127.0.0.1:${toString net.ports.victoriaMetrics}";
  interval = "30s";

  # Made at boot by victoriametrics-admin-key, below.
  adminKey = "/run/victoriametrics-admin-key";

  # The paths vmauth passes to the store, each a regular expression that must
  # match the whole path, which vmauth cleans of `.` and `..` before matching.
  # Reads alone: queries, series, labels and their values, the status pages
  # vmui's own pages call, the two query tools vmui's editor calls, and vmui
  # itself. Anything else, a write, an import or an admin path, matches no
  # route, and vmauth refuses it without asking the store.
  readPaths = [
    "/api/v1/query"
    "/api/v1/query_range"
    "/api/v1/series"
    "/api/v1/labels"
    "/api/v1/label/[^/]+/values"
    "/api/v1/metadata"
    "/api/v1/status/(buildinfo|tsdb|top_queries|active_queries|metric_names_stats)"
    "/prettify-query"
    "/expand-with-exprs"
    "/vmui(/.*)?"
  ];
  # JSON, which is YAML too.
  vmauthConfig = pkgs.writeText "vmauth.yml" (
    builtins.toJSON {
      unauthorized_user.url_map = [
        {
          src_paths = readPaths;
          url_prefix = "http://${storeAddress}";
        }
      ];
    }
  );

  # Each target at the address its exporters bind (modules/node-exporter.nix),
  # with `instance` set to the host's name rather than that address, which is
  # the label everything downstream reads, alert messages included.
  scrapeAddress =
    name: net.hosts.${name}.ip or net.segments.${net.hosts.${name}.metricsSegment}.gateway;
  staticConfigs =
    port: names:
    map (name: {
      targets = [ "${scrapeAddress name}:${toString port}" ];
      labels.instance = name;
    }) names;

  # The Fleet, DNS and DHCP dashboards, for the provider below.
  dashboards = import ./dashboards.nix { inherit lib pkgs net; };
in
{
  # The probes, whose jobs join the scrape configuration below, and the alert
  # rules over all of it.
  imports = [
    ./blackbox.nix
    ./alerting.nix
  ];

  assertions = [
    {
      assertion = hostname == net.metricsCollector;
      message = ''
        ${hostname} imports modules/metrics.nix, but net.metricsCollector is
        "${net.metricsCollector}". Every target opens its exporter to the
        collector's address alone, so a store anywhere else scrapes nothing.
      '';
    }
  ];

  services.victoriametrics = {
    enable = true;
    listenAddress = storeAddress;

    # Months, when there is no suffix.
    retentionPeriod = "12";
    extraOptions = [
      # Stop accepting samples rather than fill the disk, if the 12-month
      # estimate of 4 GB is wrong by orders of magnitude. A backstop, idle
      # unless something has already gone wrong: it acts at about 95% full, and
      # the planned DiskFilling alert fires at 85%. What is left then is weeks
      # of room for Home Assistant, the UniFi database, Docker and the nightly
      # upgrade, which share this disk, and far more than the space
      # VictoriaMetrics' own merges need at the 10 GB budget. The real margin is
      # larger: it measures space available to unprivileged users (statfs
      # Bavail), and on core5 ext4 reserves another 51 GB for root, the default
      # 5%, read with `stat -f /` on 2026-10-11.
      "-storage.minFreeDiskSpaceBytes=50GiB"
    ]
    # The admin endpoints take this key, below: deleting series
    # (`/api/v1/admin/tsdb/delete_series` and Graphite's `/tags/delSeries`),
    # making and deleting snapshots (`/snapshot/*`), forcing a merge or a
    # flush (`/internal/force_merge`, `/internal/force_flush`), reloading the
    # scrape configuration (`/-/reload`), resetting the rollup cache
    # (`/internal/resetRollupResultCache`) and the metric names' statistics
    # (`/api/v1/admin/status/metric_names_stats/reset`), logging new series
    # (`/internal/log_new_series`), and the `/config`, `/flags` and
    # `/debug/pprof/*` pages. Each flag reads a file:// value at first use and
    # every few seconds after, and refuses every key until the file is there.
    # Nothing on core5 calls any of them: the module's start check asks
    # `/ping`, which takes no key, and a changed scrape configuration restarts
    # the store rather than reloading it.
    #
    # `/metrics` is the one admin page without a key, `-metricsAuthKey`
    # unset: the store's scrape of itself, below, reads it, and a scrape
    # passes a key only as a query argument written into the scrape
    # configuration, where a key made at boot cannot be.
    ++ map (flag: "-${flag}=file://%d/admin-key") [
      "deleteAuthKey"
      "snapshotAuthKey"
      "forceMergeAuthKey"
      "forceFlushAuthKey"
      "reloadAuthKey"
      "search.resetCacheAuthKey"
      "metricNamesStatsResetAuthKey"
      "logNewSeriesAuthKey"
      "configAuthKey"
      "flagsAuthKey"
      "pprofAuthKey"
    ];

    prometheusConfig = {
      global.scrape_interval = interval;
      scrape_configs = [
        {
          job_name = "node";
          static_configs = staticConfigs net.ports.nodeExporter net.metricsTargets;
          # node_network_info carries each interface's MAC address as
          # `address`. An empty value removes the label, so it is never stored.
          metric_relabel_configs = [
            {
              source_labels = [ "__name__" ];
              regex = "node_network_info";
              target_label = "address";
              replacement = "";
            }
          ];
        }
        {
          # Unbound's statistics on each resolver (modules/unbound.nix):
          # totals, with no client and no name in them. AdGuard's counts come
          # through each resolver's node_exporter, in the job above.
          job_name = "unbound";
          static_configs = staticConfigs net.ports.unboundExporter net.resolvers;
        }
        {
          # Its own ingestion and disk use, against the budget in the doc.
          job_name = "victoriametrics";
          static_configs = [
            {
              targets = [ storeAddress ];
              labels.instance = hostname;
            }
          ];
        }
      ]
      # Kea's pool usage per segment, from gate, the one DHCP server
      # (hosts/gate/metrics.nix). Its labels are the subnets and pools from
      # lib/net.nix, and nothing about a lease or a client.
      ++ lib.optional (lib.elem "gate" net.metricsTargets) {
        job_name = "kea";
        static_configs = staticConfigs net.ports.keaExporter [ "gate" ];
      };
    };
  };

  services.grafana = {
    enable = true;

    # From `unstable`, as Home Assistant is, and for the same reason: core5's
    # package set carries nixos-raspberrypi's overlays, which change the Python
    # that Grafana's build uses, so core5's own Grafana is a derivation
    # cache.nixos.org never built, and CI would compile it, frontend and all.
    # Checked 2026-10-11, both before and after core5 moved to the fleet's
    # nixpkgs: core5's own (13.0.3, then 13.0.9) was absent from
    # cache.nixos.org and unstable's (13.1.6) was present. No override: any
    # change to the package changes its store path and loses Hydra's build.
    #
    # The costs. `unstable` moves with every flake.lock bump, and the nightly
    # upgrade applies it unattended. Grafana's database migrations are one-way,
    # so before rolling core5 back past a Grafana upgrade, delete
    # /var/lib/grafana/data/grafana.db rather than run an older Grafana on it:
    # it holds nothing provisioning does not recreate, save the admin password,
    # which is recreated from sops. The module still comes from core5's
    # nixpkgs, so module and package can drift apart; settings are free-form
    # ini, and preflight evaluates core5, which keeps that small. A new major
    # version arrives without anyone watching; the fleet dashboard uses only
    # built-in panels, which keeps that small too.
    package = unstable.grafana;
    # The Prometheus datasource, which the provisioned one below and every
    # panel use. Grafana 13.2 moved it out of Grafana's own build into a
    # plugin it fetches at start, which `preinstall_disabled` below refuses,
    # so without this every panel shows no data. From `unstable` with the
    # package, so the two move together.
    declarativePlugins = [ unstable.grafanaPlugins.prometheus ];
    settings = {
      server = {
        http_addr = host.ip;
        http_port = net.ports.grafana;
      };

      security = {
        # Read when Grafana creates its admin account, on its first start, and
        # never again. Changing the secret afterwards changes nothing; the
        # password is then changed in Grafana's own profile page.
        admin_password = "$__file{${config.sops.secrets.grafana-admin-password.path}}";
        # Encrypts secrets Grafana keeps in its database, of which there are
        # none: the one datasource is VictoriaMetrics on loopback, with no
        # credentials. So it is made on core5 at first start rather than kept
        # in sops, and losing it costs nothing.
        secret_key = "$__file{${config.services.grafana.dataDir}/secret-key}";
        disable_gravatar = true;
      };

      # Nothing leaves core5 on Grafana's account. nixpkgs already turns the
      # first two off, and they are stated so that a changed default cannot
      # turn them back on; it leaves the rest on.
      analytics = {
        reporting_enabled = false;
        check_for_updates = false;
        check_for_plugin_updates = false;
        feedback_links_enabled = false;
      };
      # At every start Grafana fetches a set of plugins from grafana.com, and
      # the keys it checks plugin signatures with, unless told not to. The
      # plugins built into it and the one in `declarativePlugins` above, which
      # are all this uses, need neither.
      plugins = {
        preinstall_disabled = true;
        public_key_retrieval_disabled = true;
      };
      news.news_feed_enabled = false;
      snapshots.external_enabled = false;
    };

    provision = {
      enable = true;
      datasources.settings = {
        apiVersion = 1;
        datasources = [
          {
            name = "VictoriaMetrics";
            uid = "victoriametrics";
            # It answers PromQL, so Grafana's Prometheus datasource is the one
            # to use, and no VictoriaMetrics plugin is needed.
            type = "prometheus";
            url = "http://${storeAddress}";
            isDefault = true;
            # The scrape interval, so `$__rate_interval` never asks rate() for
            # a window holding fewer than two samples.
            jsonData.timeInterval = interval;
          }
        ];
      };
      dashboards.settings.providers = [
        {
          name = "fleet";
          options.path = dashboards;
        }
      ];
    };
  };

  sops.secrets.grafana-admin-password.owner = "grafana";

  # lib/hardening.nix, over what nixpkgs already sets. Both modules set
  # ProtectSystem to "full", which leaves /var writable; strict narrows that
  # to each service's own state.
  systemd.services.victoriametrics.serviceConfig = hardening // {
    ProtectSystem = lib.mkForce hardening.ProtectSystem;
    LoadCredential = [ "admin-key:${adminKey}" ];
  };

  # The key VictoriaMetrics' admin endpoints take, above. Nothing calls one in
  # the normal run of things, so it is made here, once a boot, readable by
  # root alone, rather than kept in sops: losing it costs nothing, and the
  # service reads its copy as a credential. Never empty: VictoriaMetrics
  # treats an empty key as none. To delete, as root on core5, at the store's
  # own port, victoriaMetricsStore in lib/net.nix, since vmauth passes no
  # admin path:
  #
  #   curl --data-urlencode authKey@/run/victoriametrics-admin-key \
  #     --data-urlencode 'match[]=<selector>' \
  #     http://127.0.0.1:<store port>/api/v1/admin/tsdb/delete_series
  systemd.services.victoriametrics-admin-key = {
    description = "Make the key VictoriaMetrics' admin APIs take";
    before = [ "victoriametrics.service" ];
    requiredBy = [ "victoriametrics.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
    };
    script = ''
      if [ ! -s ${adminKey} ]; then
        key=$(${lib.getExe pkgs.openssl} rand -hex 32)
        printf '%s' "$key" > ${adminKey}
      fi
    '';
  };

  # Queries reach the store through vmauth, which passes `readPaths`, above,
  # and refuses the rest. It listens at the port that was the store's, so a
  # query sent there is unchanged, and the diag login, which modules/diag-login.nix
  # refuses the store's own port, reaches the store through it alone. Its own
  # pages, `/metrics`, `/flags`, `/-/reload` and `/debug/pprof/*`, are on a
  # socket in its runtime directory, which its user and root alone open, so
  # its port serves the routes above and nothing else. nixpkgs has no module
  # for it; the binary is the store's own package's.
  systemd.services.vmauth = {
    description = "Pass reads alone to VictoriaMetrics";
    wantedBy = [ "multi-user.target" ];
    # Its port was the store's, until the store moved; on that switch, the
    # store's restart frees it first.
    after = [ "victoriametrics.service" ];
    serviceConfig = hardening // {
      ExecStart = lib.escapeShellArgs [
        (lib.getExe' config.services.victoriametrics.package "vmauth")
        "-auth.config=${vmauthConfig}"
        "-httpListenAddr=${vmauthAddress}"
        "-httpInternalListenAddr=unix:/run/vmauth/internal.sock"
      ];
      DynamicUser = true;
      RuntimeDirectory = "vmauth";
      RuntimeDirectoryMode = "0700";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  systemd.services.grafana = {
    serviceConfig = hardening // {
      ProtectSystem = lib.mkForce hardening.ProtectSystem;
      ReadWritePaths = [ config.services.grafana.dataDir ];
    };
    preStart = ''
      if [ ! -s ${config.services.grafana.dataDir}/secret-key ]; then
        (umask 077; ${lib.getExe pkgs.openssl} rand -hex 32 | tr -d '\n' > ${config.services.grafana.dataDir}/secret-key)
      fi
    '';
  };

  # Grafana is the one listener on core5's address; VictoriaMetrics and vmauth
  # are on loopback. The LAN interface only, as for Home Assistant: servers reaches it
  # directly, trusted through gate, and no other segment at all.
  networking.firewall.interfaces.${host.iface}.allowedTCPPorts = [ net.ports.grafana ];
}
