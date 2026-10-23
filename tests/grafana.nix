# Grafana on the collector answers a query through its provisioned datasource,
# with both dashboards provisioned. core5 runs Grafana from `unstable`, which
# every flake.lock bump moves, and Grafana 13.2 moved the Prometheus datasource
# out of its own build into a plugin: Grafana still started and served both
# dashboards, but every panel showed no data. This catches the next such move
# in the pull request that brings it, before core5 takes it at night.
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

  testScript = ''
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

    with subtest("both dashboards are provisioned"):
        out = ${collector}.succeed(f"curl -sf {grafana}/api/search")
        for uid in ("fleet", "dns"):
            assert f'"uid":"{uid}"' in out, out

    with subtest("the datasource answers its health check"):
        out = ${collector}.succeed(f"curl -s {grafana}/api/datasources/uid/victoriametrics/health")
        assert '"status":"OK"' in out, out

    with subtest("a query through the datasource returns the store's series"):
        body = '{"queries":[{"refId":"A","datasource":{"uid":"victoriametrics"},"expr":"grafana_test_metric","instant":true}],"from":"now-5m","to":"now"}'
        out = ${collector}.succeed(f"curl -s -H 'Content-Type: application/json' -d '{body}' {grafana}/api/ds/query")
        assert '"status":200' in out and "grafana_test_metric" in out, out
  '';
}
