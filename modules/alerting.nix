# Alerts over the fleet's metrics, on the collector: vmalert evaluates the rules
# in ./alert-rules.nix against VictoriaMetrics, and Alertmanager delivers what
# fires to the ntfy topic the phone follows, the one modules/alerts.nix already
# posts to. Imported by modules/metrics.nix. docs/observability.md, "Alerts",
# has the design; this file has what implementing it needed.
#
# Delivery. ntfy.sh formats Alertmanager's webhook itself
# (`?template=alertmanager`), so nothing runs between the two. Each severity is
# a receiver of its own, which differs only in the priority it asks ntfy for.
# The URLs are sops templates over the `ntfy-url` and `healthchecks-ping-key`
# secrets core5 already holds, handed to Alertmanager as systemd credentials
# and read through `url_file`, so the topic never reaches the store or the
# process list.
#
# One push per incident. Alertmanager groups by alert name, so a fault seen on
# several hosts at once is one push, and a host joining the group later is
# another. It never sends a resolution, and repeats a push only after 30 days
# of the same alerts still firing; the notification log that remembers what was
# sent is kept for 31, since at its default of 5 days an unresolved alert would
# push again every 5 days. vmalert writes each alert's state to the store and
# reads it back at start, so a restart does not reset an alert's `for` and send
# it again as a new one.
#
# What leaves the house is the whole webhook body, which the ntfy template
# formats: each alert's labels and annotations, held to names in
# ./alert-rules.nix, and the two services' own URLs, which are set here to
# loopback addresses rather than left to default to the host's name.
#
# What this cannot see is core5 itself failing, or the WAN: an alert that
# cannot leave the house arrives when it can. The Watchdog covers both from
# outside, through healthchecks.io, and fleetAlerts covers each service here
# failing to start (hosts/core5).
{
  config,
  lib,
  pkgs,
  hostname,
  net,
  ...
}:
let
  vm = "http://127.0.0.1:${toString net.ports.victoriaMetrics}";
  vmalertAddress = "127.0.0.1:${toString net.ports.vmalert}";
  alertmanagerAddress = "127.0.0.1:${toString net.ports.alertmanager}";
  ph = config.sops.placeholder;

  # Where node_exporter's textfile collector reads (modules/node-exporter.nix),
  # for main's head, below.
  textfileDir = "/run/fleet-metrics";

  # The repository the Pis upgrade from. Its default branch is what they run
  # after a good night, so RevisionBehind compares against its head.
  upgradeFlake = config.system.autoUpgrade.flake;
  repo = lib.removePrefix "github:" upgradeFlake;

  rules = import ./alert-rules.nix { inherit lib net hostname; };

  # Each receiver's URL, as a credential Alertmanager reads at each push.
  urls = {
    critical = "${ph.ntfy-url}?template=alertmanager&priority=high";
    warning = "${ph.ntfy-url}?template=alertmanager";
    info = "${ph.ntfy-url}?template=alertmanager&priority=low";
    # A check named for this host, like modules/alerts.nix's, created by its
    # first ping. Its period is set by hand (README, "Alerts").
    watchdog = "https://hc-ping.com/${ph.healthchecks-ping-key}/${hostname}-metrics-watchdog?create=1";
  };
  credential = name: "/run/credentials/alertmanager.service/${name}";
  receiver = name: {
    inherit name;
    webhook_configs = [
      {
        url_file = credential name;
        send_resolved = false;
      }
    ];
  };

  # main's head, for RevisionBehind. Unauthenticated, as anyone may read a
  # public repository: two requests an hour, of the 60 GitHub allows an
  # address. A failed read leaves the last one in place, with its time.
  mainRevision = pkgs.writeShellApplication {
    name = "fleet-main-revision";
    runtimeInputs = with pkgs; [
      coreutils
      curl
    ];
    text = ''
      head=$(curl -fsS --max-time 30 --retry 3 -H 'Accept: application/vnd.github.sha' \
        https://api.github.com/repos/${repo}/commits/HEAD)
      if ! [[ $head =~ ^[0-9a-f]{40}$ ]]; then
        echo "GitHub's answer is not a commit hash" >&2
        exit 1
      fi

      tmp=$(mktemp -p ${textfileDir})
      {
        echo '# HELP fleet_main_revision_info The head of the default branch the Pis upgrade from.'
        echo '# TYPE fleet_main_revision_info gauge'
        printf 'fleet_main_revision_info{revision="%s"} 1\n' "$head"
        echo '# HELP fleet_main_revision_checked_timestamp_seconds When that head was read.'
        echo '# TYPE fleet_main_revision_checked_timestamp_seconds gauge'
        echo "fleet_main_revision_checked_timestamp_seconds $(date +%s)"
      } >"$tmp"
      chmod 0644 "$tmp"
      mv "$tmp" ${textfileDir}/main.prom
    '';
  };
in
{
  assertions = [
    {
      assertion = lib.hasPrefix "github:" upgradeFlake;
      message = ''
        modules/alerting.nix reads main's head from GitHub, for RevisionBehind,
        but system.autoUpgrade.flake is "${upgradeFlake}", not a github: flake.
      '';
    }
  ];

  services.vmalert.instances."" = {
    enable = true;
    inherit rules;
    settings = {
      "datasource.url" = vm;
      "notifier.url" = [ "http://${alertmanagerAddress}" ];
      # Its alerts' state, written to the store and read back at start.
      "remoteWrite.url" = vm;
      "remoteRead.url" = vm;
      evaluationInterval = "30s";
      httpListenAddr = vmalertAddress;
      # The link each alert carries, which would otherwise name the host.
      "external.url" = "http://${vmalertAddress}";
    };
  };

  services.prometheus.alertmanager = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = net.ports.alertmanager;
    webExternalUrl = "http://${alertmanagerAddress}";
    extraFlags = [
      # Clustering is on by default, gossiping on every address, and there is
      # one Alertmanager.
      "--cluster.listen-address="
      # Past the longest repeat interval below, or an alert still firing would
      # be forgotten and pushed again.
      "--data.retention=744h"
    ];
    configuration = {
      route = {
        receiver = "warning";
        group_by = [ "alertname" ];
        # Long enough for alerts with one cause to arrive together.
        group_wait = "30s";
        group_interval = "5m";
        repeat_interval = "30d";
        routes = [
          {
            # A ping every 5 minutes, or a little more, against a check
            # whose period is 15.
            matchers = [ ''alertname="Watchdog"'' ];
            receiver = "watchdog";
            group_wait = "10s";
            group_interval = "1m";
            repeat_interval = "5m";
          }
          {
            matchers = [ ''severity="critical"'' ];
            receiver = "critical";
          }
          {
            matchers = [ ''severity="info"'' ];
            receiver = "info";
          }
        ];
      };
      receivers = map receiver (lib.attrNames urls);
      inhibit_rules = [
        {
          # A host that is down says nothing else worth hearing.
          source_matchers = [ ''alertname="HostDown"'' ];
          target_matchers = [ ''alertname!~"HostDown|Watchdog"'' ];
          equal = [ "instance" ];
        }
        {
          # With the WAN down, every recursion fails.
          source_matchers = [ ''alertname="WanDown"'' ];
          target_matchers = [ ''alertname="ResolverFailing"'' ];
        }
      ];
    };
  };

  sops.secrets.ntfy-url = { };
  sops.secrets.healthchecks-ping-key = { };
  sops.templates = lib.mapAttrs' (
    name: url:
    lib.nameValuePair "alertmanager-${name}-url" {
      content = url;
      restartUnits = [ "alertmanager.service" ];
    }
  ) urls;

  systemd.services.alertmanager.serviceConfig.LoadCredential = lib.mapAttrsToList (
    name: _: "${name}:${config.sops.templates."alertmanager-${name}-url".path}"
  ) urls;

  systemd.services.vmalert = {
    after = [ "victoriametrics.service" ];
    serviceConfig = import ../lib/hardening.nix;
  };

  # Both answer their own metrics, which the store keeps beside its own.
  services.victoriametrics.prometheusConfig.scrape_configs =
    map
      (
        { job, address }:
        {
          job_name = job;
          static_configs = [
            {
              targets = [ address ];
              labels.instance = hostname;
            }
          ];
        }
      )
      [
        {
          job = "vmalert";
          address = vmalertAddress;
        }
        {
          job = "alertmanager";
          address = alertmanagerAddress;
        }
      ];

  systemd.services.fleet-main-revision = {
    description = "Read the head of the branch the Pis upgrade from, for node_exporter";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = import ../lib/hardening.nix // {
      Type = "oneshot";
      ExecStart = lib.getExe mainRevision;
      # As modules/node-exporter.nix's facts, into the same directory.
      User = config.services.prometheus.exporters.node.user;
      RuntimeDirectory = baseNameOf textfileDir;
      RuntimeDirectoryMode = "0755";
      RuntimeDirectoryPreserve = true;
    };
  };
  systemd.timers.fleet-main-revision = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "30min";
    };
  };
}
