# Grafana on the collector answers a query through its provisioned datasource,
# with every dashboard provisioned. core5 runs Grafana from `unstable`, which
# every flake.lock bump moves, and Grafana 13.2 moved the Prometheus datasource
# out of its own build into a plugin: Grafana still started and served the
# dashboards, but every panel showed no data. This catches the next such move
# in the pull request that brings it, before core5 takes it at night.
#
# And every panel's queries are ones the store can run: each expression in the
# files Grafana is given goes to the store, so one it rejects fails here rather
# than drawing nothing. A misspelt metric or label still runs and finds
# nothing, which passes, since no exporter runs here; the dashboards' own
# check after core5 upgrades is what catches that.
#
# And the store's two ports, as modules/metrics.nix sets them: vmauth's, at
# VictoriaMetrics' usual port, passes queries and vmui and refuses writes,
# imports and admin paths; the store's own takes writes, vmalert's among them,
# and its scrape of itself; and each admin endpoint there takes the key, which
# root reads.
#
# `nix build .#checks.x86_64-linux.grafana`. It needs KVM, which forge's daemon
# has; CI's vm-tests job runs it on pull requests.
#
# core5 is modules/metrics.nix itself, which brings the probes and the alerting
# stack with it, on core5's address. The other hosts' targets are absent, so
# their scrapes fail, which is harmless; the series queried is one the test
# imports. sops-nix is a stand-in, as in ./alerting.nix, and the secrets are
# test values.
{ net, unstable }:
let
  collector = net.metricsCollector;
  host = net.hosts.${collector};

  # Test value only: core5's own is in sops.
  password = "test-password";

  # What vmauth answers a path that matches no route.
  refusedStatus = 400;

  sopsStub =
    { lib, pkgs, ... }:
    {
      options.sops = {
        secrets = lib.mkOption {
          type = lib.types.attrsOf lib.types.attrs;
          default = { };
        };
        placeholder = lib.mkOption { type = lib.types.attrsOf lib.types.str; };
        templates = lib.mkOption {
          default = { };
          type = lib.types.attrsOf (
            lib.types.submodule (
              { name, config, ... }:
              {
                options.content = lib.mkOption { type = lib.types.str; };
                options.restartUnits = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                };
                options.path = lib.mkOption {
                  type = lib.types.str;
                  default = toString (pkgs.writeText name config.content);
                };
              }
            )
          );
        };
      };
      config.sops = {
        secrets.grafana-admin-password.path = toString (pkgs.writeText "grafana-admin-password" password);
        placeholder = {
          ntfy-url = "https://ntfy.sh/test-topic";
          healthchecks-ping-key = "test-ping-key";
        };
      };
    };
in
{
  name = "grafana";

  node.specialArgs = {
    inherit net unstable;
    hostname = collector;
  };

  nodes.${collector} =
    { lib, ... }:
    {
      imports = [
        sopsStub
        ../modules/metrics.nix
        ../modules/kernel-hardening.nix
      ];

      virtualisation.memorySize = 2048;
      # The store turns read-only below `-storage.minFreeDiskSpaceBytes`, 50 GiB
      # in modules/metrics.nix, and would take neither scrapes nor the import
      # below. The image is sparse, so this costs no space.
      virtualisation.diskSize = 60 * 1024;
      virtualisation.interfaces.${host.iface}.vlan = 1;
      networking = {
        useDHCP = false;
        interfaces.${host.iface}.ipv4.addresses = [
          {
            address = host.ip;
            inherit (net.segments.${host.segment}) prefixLength;
          }
        ];
      };

      # baseline.nix's, which modules/alerting.nix reads; nothing upgrades here.
      system.autoUpgrade.flake = "github:nnorx/nix-config";
      # It would ask GitHub, which no VM reaches.
      systemd.timers.fleet-main-revision.wantedBy = lib.mkForce [ ];
    };

  testScript =
    { nodes, ... }:
    let
      # The directory modules/metrics.nix points Grafana's provider at.
      provider =
        builtins.head
          nodes.${collector}.services.grafana.provision.dashboards.settings.providers;
    in
    ''
      import json
      import re
      import shlex

      grafana = "http://admin:${password}@${host.ip}:${toString net.ports.grafana}"

      start_all()
      ${collector}.wait_for_unit("victoriametrics.service")
      ${collector}.wait_for_open_port(${toString net.ports.grafana}, "${host.ip}")
      # The store's own port, which Grafana and vmalert use, and vmauth's in
      # front of it, which queries from a login use.
      store = "http://127.0.0.1:${toString net.ports.victoriaMetricsStore}"
      vmauth = "http://127.0.0.1:${toString net.ports.victoriaMetrics}"
      ${collector}.wait_for_unit("vmauth.service")
      ${collector}.wait_for_open_port(${toString net.ports.victoriaMetrics}, "127.0.0.1")
      # One series of its own, so the query below does not wait on a scrape.
      ${collector}.succeed(f"curl -sf -d 'grafana_test_metric 1' {store}/api/v1/import/prometheus")
      ${collector}.wait_until_succeeds(
          f"curl -sf '{store}/api/v1/query?query=grafana_test_metric' | grep -q grafana_test_metric",
          timeout=60,
      )

      # Every dashboard file the provider is given, by name.
      directory = "${provider.options.path}"
      boards = {
          name: json.loads(${collector}.succeed(f"cat {directory}/{name}"))
          for name in ${collector}.succeed(f"ls {directory}").split()
      }

      with subtest("every dashboard is provisioned"):
          uids = {board["uid"] for board in boards.values()}
          # The four this repo has, so a file going missing fails too.
          missing = {"fleet", "dns", "dhcp", "alerting"} - uids
          assert not missing, f"no dashboard file for {sorted(missing)}"
          out = ${collector}.succeed(f"curl -sf {grafana}/api/search")
          for uid in uids:
              assert f'"uid":"{uid}"' in out, f"{uid} not provisioned: {out}"

      with subtest("the datasource answers its health check"):
          out = ${collector}.succeed(f"curl -s {grafana}/api/datasources/uid/victoriametrics/health")
          assert '"status":"OK"' in out, out

      with subtest("a query through the datasource returns the store's series"):
          body = '{"queries":[{"refId":"A","datasource":{"uid":"victoriametrics"},"expr":"grafana_test_metric","instant":true}],"from":"now-5m","to":"now"}'
          out = ${collector}.succeed(f"curl -s -H 'Content-Type: application/json' -d '{body}' {grafana}/api/ds/query")
          assert '"status":200' in out and "grafana_test_metric" in out, out

      with subtest("every panel's queries are ones the store accepts"):
          # Grafana's own variables, which it fills in before asking the store
          # and the store does not know, each by its whole name, as a fixed
          # window. One not listed fails, rather than being sent as written.
          # An empty answer passes: most of these series are absent here.
          variables = {
              "__rate_interval": "1m",
              "__interval": "30s",
              "__interval_ms": "30000",
              "__range": "1h",
              "__range_s": "3600",
              "__range_ms": "3600000",
          }

          def fill(where, expr):
              def one(match):
                  assert match.group(1) in variables, f"{where}: Grafana variable ''${match.group(1)} has no stand-in here"
                  return variables[match.group(1)]
              return re.sub(r"\$(__\w+)", one, expr)

          for name, board in boards.items():
              checked = 0
              for panel in board["panels"]:
                  for target in panel["targets"]:
                      where = f"{name}, {panel['title']}, {target['refId']}"
                      query = shlex.quote(f"query={fill(where, target['expr'])}")
                      out = ${collector}.succeed(f"curl -s -G --data-urlencode {query} {store}/api/v1/query")
                      assert '"status":"success"' in out, f"{where}: {out}"
                      checked += 1
              assert checked > 0, f"{name}: no panel queries were found to check"

      def status(method, url, data=None):
          """The HTTP status of one request, with the path sent as written."""
          body = f"--data-binary {shlex.quote(data)} " if data is not None else ""
          return int(${collector}.succeed(
              f"curl -s --path-as-is -o /dev/null -w '%{{http_code}}' -X {method} {body}{shlex.quote(url)}"
          ))

      def count(metric):
          """How many series the store holds under `metric`, asked directly."""
          out = json.loads(${collector}.succeed(f"curl -sf '{store}/api/v1/series' --data-urlencode 'match[]={metric}'"))
          return len(out["data"])

      with subtest("through vmauth, queries and vmui answer"):
          out = ${collector}.succeed(f"curl -sf '{vmauth}/api/v1/query?query=grafana_test_metric'")
          assert "grafana_test_metric" in out, out
          for path in [
              "/api/v1/query_range?query=grafana_test_metric&start=-5m&step=30s",
              "/api/v1/series?match[]=grafana_test_metric",
              "/api/v1/labels",
              "/api/v1/label/__name__/values",
              "/api/v1/status/tsdb",
              "/api/v1/status/buildinfo",
          ]:
              out = ${collector}.succeed(f"curl -sf -g '{vmauth}{path}'")
              assert '"status":"success"' in out, f"{path}: {out}"
          out = ${collector}.succeed(f"curl -sfL {vmauth}/vmui/")
          assert "<html" in out.lower(), out[:500]

      with subtest("through vmauth, writes, imports and admin paths are refused"):
          refused = [
              ("POST", "/api/v1/import/prometheus", "vmauth_injected 1"),
              ("POST", "/api/v1/import", '{"metric":{"__name__":"vmauth_injected"},"values":[1],"timestamps":[0]}'),
              ("POST", "/api/v1/import/csv?format=2:metric:vmauth_injected", "1"),
              ("POST", "/api/v1/write", ""),
              ("POST", "/write", "vmauth_injected value=1"),
              ("POST", "/influx/write", "vmauth_injected value=1"),
              ("POST", "/influx/api/v2/write", "vmauth_injected value=1"),
              ("POST", "/prometheus/api/v1/import/prometheus", "vmauth_injected 1"),
              ("POST", "/datadog/api/v1/series", "{}"),
              ("POST", "/opentelemetry/v1/metrics", ""),
              ("GET", "/api/v1/export?match[]=grafana_test_metric", None),
              ("POST", "/api/v1/admin/tsdb/delete_series?match[]=grafana_test_metric", None),
              ("GET", "/snapshot/create", None),
              ("GET", "/internal/force_merge", None),
              ("GET", "/-/reload", None),
              ("GET", "/flags", None),
              ("GET", "/metrics", None),
              ("GET", "/debug/pprof/", None),
              # vmauth cleans the path before it matches a route.
              ("POST", "/vmui/../api/v1/import/prometheus", "vmauth_injected 1"),
              ("POST", "/api/v1/query/../import/prometheus", "vmauth_injected 1"),
              ("POST", "/vmui/%2e%2e/api/v1/import/prometheus", "vmauth_injected 1"),
          ]
          for method, path, data in refused:
              code = status(method, f"{vmauth}{path}", data)
              assert code == ${toString refusedStatus}, f"{method} {path} through vmauth: {code}"
          # The series path is a read whatever the method, so a DELETE through
          # vmauth reaches the store and removes nothing.
          status("DELETE", f"{vmauth}/api/v1/series?match[]=grafana_test_metric")
          assert count("grafana_test_metric") == 1, "a DELETE through vmauth removed a series"
          ${collector}.succeed(f"curl -sf \"{store}/internal/force_flush?authKey=$(cat /run/victoriametrics-admin-key)\"")
          assert count("vmauth_injected") == 0, "a write through vmauth reached the store"

      with subtest("the store's own port takes writes, vmalert's among them"):
          ${collector}.succeed(f"curl -sf -d 'store_write_test 1' {store}/api/v1/import/prometheus")
          ${collector}.wait_until_succeeds(
              f"curl -sf '{store}/api/v1/query?query=store_write_test' | grep -q store_write_test",
              timeout=60,
          )
          # vmalert writes each alert's state there, and the Watchdog always fires.
          ${collector}.wait_until_succeeds(
              f"curl -sf -g '{store}/api/v1/query?query=ALERTS{{alertname=\"Watchdog\"}}' | grep -q Watchdog",
              timeout=120,
          )

      with subtest("the store scrapes itself at its own port, without a key"):
          ${collector}.wait_until_succeeds(
              f"curl -sf -g '{store}/api/v1/query?query=up{{job=\"victoriametrics\"}}==1' | grep -q victoriametrics",
              timeout=120,
          )

      with subtest("each admin endpoint takes the key, which root reads"):
          ${collector}.succeed("test -s /run/victoriametrics-admin-key")
          ${collector}.succeed("test \"$(stat -c %a:%U /run/victoriametrics-admin-key)\" = 600:root")
          key = ${collector}.succeed("cat /run/victoriametrics-admin-key").strip()
          keyed = [
              ("POST", "/api/v1/admin/tsdb/delete_series?match[]=no_such_metric"),
              ("GET", "/snapshot/list"),
              ("GET", "/internal/force_merge"),
              ("GET", "/internal/force_flush"),
              ("GET", "/-/reload"),
              ("GET", "/internal/resetRollupResultCache"),
              ("POST", "/api/v1/admin/status/metric_names_stats/reset"),
              ("GET", "/internal/log_new_series"),
              ("GET", "/config"),
              ("GET", "/flags"),
              ("GET", "/debug/pprof/cmdline"),
          ]
          for method, path in keyed:
              join = "&" if "?" in path else "?"
              without = status(method, f"{store}{path}")
              assert without == 401, f"{method} {path} without the key: {without}"
              wrong = status(method, f"{store}{path}{join}authKey=wrong")
              assert wrong == 401, f"{method} {path} with a wrong key: {wrong}"
              right = status(method, f"{store}{path}{join}authKey={key}")
              assert 200 <= right < 300, f"{method} {path} with the key: {right}"
    '';
}
