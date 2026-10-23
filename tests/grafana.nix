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
      # One series of its own, so the query below does not wait on a scrape.
      store = "http://127.0.0.1:${toString net.ports.victoriaMetrics}"
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
          # The three this repo has, so a file going missing fails too.
          missing = {"fleet", "dns", "dhcp"} - uids
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
    '';
}
