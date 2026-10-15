# The dashboards Grafana provisions on the collector, as a directory of JSON
# files for modules/metrics.nix to point its provider at. A function rather
# than a module: metrics.nix imports it with `import`, not `imports`.
#
# Each dashboard is its panels in reading order. A panel gives its size only,
# 12 columns by 8 rows unless it says otherwise, and `layout` places it.
{ lib, pkgs }:
let
  datasource = {
    type = "prometheus";
    uid = "victoriametrics";
  };

  # Grafana's names for a panel's queries: A to Z, then AA, AB and on.
  refId = i: (if i >= 26 then refId (i / 26 - 1) else "") + lib.elemAt lib.upperChars (lib.mod i 26);

  panel =
    {
      title,
      targets,
      type ? "timeseries",
      unit ? "short",
      width ? 12,
      height ? 8,
      options ? { },
      fieldConfig ? { },
      transformations ? [ ],
    }:
    {
      inherit
        title
        type
        datasource
        options
        transformations
        ;
      gridPos = {
        w = width;
        h = height;
      };
      targets = lib.imap0 (
        i: t:
        {
          inherit datasource;
          refId = refId i;
          legendFormat = "{{instance}}";
        }
        // t
      ) targets;
      fieldConfig = lib.recursiveUpdate { defaults.unit = unit; } fieldConfig;
    };

  # Places panels left to right on Grafana's 24-column grid, starting a new
  # row when the next would not fit. A row is as tall as its tallest panel,
  # so panels sharing a row should share a height: Grafana floats a panel up
  # into any gap above it, which would put it out of reading order.
  layout =
    panels:
    (lib.foldl'
      (
        row: p:
        let
          wraps = row.x + p.gridPos.w > 24;
          x = if wraps then 0 else row.x;
          y = if wraps then row.y + row.height else row.y;
        in
        {
          x = x + p.gridPos.w;
          inherit y;
          height = if wraps then p.gridPos.h else lib.max row.height p.gridPos.h;
          placed = row.placed ++ [ (lib.recursiveUpdate p { gridPos = { inherit x y; }; }) ];
        }
      )
      {
        x = 0;
        y = 0;
        height = 0;
        placed = [ ];
      }
      panels
    ).placed;

  dashboard =
    { uid, title }:
    panels: {
      inherit uid title;
      schemaVersion = 39;
      time = {
        from = "now-24h";
        to = "now";
      };
      refresh = "1m";
      panels = layout panels;
    };

  # The network panel leaves out loopback and Docker's interfaces, which on
  # core5 would count each container's traffic a second time.
  physical = ''device!~"lo|veth.*|docker.*|br-.*"'';

  # An up-or-down stat, each series a coloured tile.
  upOptions = {
    colorMode = "background";
    textMode = "value_and_name";
    reduceOptions.calcs = [ "lastNotNull" ];
  };
  upMappings = [
    {
      type = "value";
      options = {
        "0" = {
          text = "down";
          color = "red";
        };
        "1" = {
          text = "up";
          color = "green";
        };
      };
    }
  ];

  # The fleet dashboard. Small on purpose: whether each host is up and what it
  # is running, then the resources most likely to explain a problem, one line
  # per host. Community dashboards can sit beside it in the same directory.
  fleetDashboard =
    dashboard
      {
        uid = "fleet";
        title = "Fleet";
      }
      [
        (panel {
          title = "Up";
          type = "stat";
          width = 10;
          height = 6;
          targets = [ { expr = ''up{job="node"}''; } ];
          options = upOptions;
          fieldConfig.defaults.mappings = upMappings;
        })
        (panel {
          title = "Running";
          type = "table";
          width = 14;
          height = 6;
          # One row per host: the revision it runs and the device its root is on.
          targets = [
            {
              expr = "fleet_revision_info * on (instance) group_left (device) fleet_root_device_info";
              instant = true;
              format = "table";
            }
          ];
          transformations = [
            {
              id = "organize";
              options.excludeByName = {
                Time = true;
                job = true;
                Value = true;
              };
            }
          ];
        })
        (panel {
          title = "CPU busy";
          unit = "percentunit";
          targets = [
            {
              expr = ''1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[$__rate_interval]))'';
            }
          ];
        })
        (panel {
          title = "Memory used";
          unit = "percentunit";
          targets = [ { expr = "1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes"; } ];
        })
        (panel {
          title = "Root filesystem used";
          unit = "percentunit";
          targets = [
            {
              expr = ''1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}'';
            }
          ];
        })
        (panel {
          title = "Hottest thermal zone";
          unit = "celsius";
          targets = [ { expr = "max by (instance) (node_thermal_zone_temp)"; } ];
        })
        (panel {
          title = "Network";
          unit = "bps";
          targets = [
            {
              expr = "8 * sum by (instance) (rate(node_network_receive_bytes_total{${physical}}[$__rate_interval]))";
              legendFormat = "{{instance}} in";
            }
            {
              expr = "8 * sum by (instance) (rate(node_network_transmit_bytes_total{${physical}}[$__rate_interval]))";
              legendFormat = "{{instance}} out";
            }
          ];
        })
        (panel {
          title = "Load, 5 minutes";
          targets = [ { expr = "node_load5"; } ];
        })
        (panel {
          title = "Public resolvers answering pings";
          unit = "percentunit";
          # From core5 through gate and out of wan (modules/blackbox.nix): the
          # share of echo requests answered, which falls to nothing when the
          # house's traffic stops leaving it.
          targets = [ { expr = ''avg_over_time(probe_success{job="probe-ping"}[$__rate_interval])''; } ];
        })
        (panel {
          title = "Public resolvers, round trip";
          unit = "s";
          targets = [ { expr = ''probe_icmp_duration_seconds{job="probe-ping", phase="rtt"}''; } ];
        })
      ];

  # Each resolver's health, one line per resolver, from Unbound's exporter and
  # AdGuard's counts (modules/unbound.nix, modules/adguardhome.nix). Nothing
  # here can be split by client: neither source has one. AdGuard's counts
  # leave the work segment out, and Unbound's include it in their totals.
  rate = expr: "rate(${expr}[$__rate_interval])";
  perResolver = expr: "sum by (instance) (${rate expr})";
  ratio = num: den: "${perResolver num} / ${perResolver den}";
  dnsDashboard =
    dashboard
      {
        uid = "dns";
        title = "DNS";
      }
      [
        (panel {
          title = "Queries per second";
          # AdGuard's count is every client but the work segment. Unbound's is
          # what AdGuard forwarded, which is everything it did not block,
          # work's included.
          targets = [
            {
              expr = perResolver "fleet_adguard_queries_total";
              legendFormat = "{{instance}} AdGuard";
            }
            {
              expr = perResolver "unbound_queries_total";
              legendFormat = "{{instance}} Unbound";
            }
          ];
        })
        (panel {
          title = "Blocked";
          unit = "percentunit";
          targets = [ { expr = ratio "fleet_adguard_blocked_total" "fleet_adguard_queries_total"; } ];
        })
        (panel {
          title = "SERVFAIL";
          unit = "percentunit";
          # Of Unbound's answers. A recursion that timed out upstream, and an
          # answer that failed DNSSEC validation, both end here. `nodata` is
          # left out of the whole: those are NOERROR answers, counted again.
          targets = [
            {
              expr = ratio ''unbound_answer_rcodes_total{rcode="SERVFAIL"}'' ''unbound_answer_rcodes_total{rcode!="nodata"}'';
            }
          ];
        })
        (panel {
          title = "Timeouts";
          unit = "percentunit";
          # The two places a query goes unanswered in time. AdGuard asks its
          # fallback only when Unbound errs or takes longer than
          # upstream_timeout, so the fallback's share of AdGuard's upstream
          # answers is Unbound timing out from AdGuard's side. Unbound's own
          # drops are queries it discarded unanswered: too long in its queue,
          # or its request list full.
          targets = [
            {
              expr = ratio ''fleet_adguard_upstream_responses_total{upstream!="primary"}'' "fleet_adguard_upstream_responses_total";
              legendFormat = "{{instance}} answered by fallback";
            }
            {
              expr = ratio ''{__name__=~"unbound_(queries_discard_timeout|queries_wait_limit|request_list_exceeded_total)"}'' "unbound_queries_total";
              legendFormat = "{{instance}} dropped by Unbound";
            }
          ];
        })
        (panel {
          title = "Cache hits";
          unit = "percentunit";
          # Unbound's cache, which is the only one: AdGuard's is off.
          targets = [ { expr = ratio "unbound_cache_hits_total" "unbound_queries_total"; } ];
        })
        (panel {
          title = "Latency";
          unit = "s";
          # Unbound's recursion, which is cache misses alone, and what clients
          # wait on AdGuard for, cache hits and blocks included.
          targets = [
            {
              expr = "histogram_quantile(0.5, sum by (instance, le) (${rate "unbound_response_time_seconds_bucket"}))";
              legendFormat = "{{instance}} recursion, median";
            }
            {
              expr = "histogram_quantile(0.9, sum by (instance, le) (${rate "unbound_response_time_seconds_bucket"}))";
              legendFormat = "{{instance}} recursion, 90th percentile";
            }
            {
              expr = ratio "fleet_adguard_processing_seconds_total" "fleet_adguard_queries_total";
              legendFormat = "{{instance}} AdGuard answer, mean";
            }
            {
              expr = ratio ''fleet_adguard_upstream_seconds_total{upstream="primary"}'' ''fleet_adguard_upstream_responses_total{upstream="primary"}'';
              legendFormat = "{{instance}} AdGuard to Unbound, mean";
            }
          ];
        })
        (panel {
          title = "DNSSEC failures per second";
          # Answers that failed validation, which clients get as SERVFAIL, and
          # the records Unbound found bogus on the way to them.
          targets = [
            {
              expr = perResolver "unbound_answers_bogus";
              legendFormat = "{{instance}} answers";
            }
            {
              expr = perResolver "unbound_rrset_bogus_total";
              legendFormat = "{{instance}} records";
            }
          ];
        })
        (panel {
          title = "Sources up";
          type = "stat";
          targets = [
            {
              # The scrape, and the exporter reaching Unbound behind it.
              expr = ''min by (instance) ({job="unbound", __name__=~"up|unbound_up"})'';
              legendFormat = "{{instance}} Unbound";
            }
            {
              expr = "fleet_adguard_up";
              legendFormat = "{{instance}} AdGuard";
            }
          ];
          options = upOptions;
          fieldConfig.defaults.mappings = upMappings;
        })
        (panel {
          title = "Answering, from core5";
          unit = "percentunit";
          # The share of core5's probes each resolver answered, through AdGuard
          # on port 53, with the NXDOMAIN Unbound gives its probe name
          # (modules/blackbox.nix). It needs neither the WAN nor recursion, so a
          # WAN outage shows in SERVFAIL, not here.
          targets = [ { expr = ''avg_over_time(probe_success{job="probe-resolver"}[$__rate_interval])''; } ];
        })
        (panel {
          title = "Answer time, from core5";
          unit = "s";
          targets = [ { expr = ''probe_dns_duration_seconds{job="probe-resolver", phase="request"}''; } ];
        })
      ];
in
pkgs.linkFarm "fleet-dashboards" {
  "fleet.json" = pkgs.writeText "fleet.json" (builtins.toJSON fleetDashboard);
  "dns.json" = pkgs.writeText "dns.json" (builtins.toJSON dnsDashboard);
}
