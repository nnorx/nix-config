# Journals into VictoriaLogs on the collector (modules/logs.nix,
# modules/journal-upload.nix): a `logger` line on core4, on gate's servers
# address and on core5 itself is found in the store; a line written before an
# upload's first start is not sent; a unit in gate's Kea namespace stays on
# gate. And a client reaches the upload path alone: vmauth refuses select,
# delete, other ingestion and admin paths, and the store's port is closed to
# it. On loopback, delete is off and the admin endpoints take the key, and
# the query vmauth passes reads alone.
#
# `nix build .#checks.x86_64-linux.journal-upload`. It needs KVM, which
# forge's daemon has; CI's vm-tests job runs it on pull requests.
{ net, unstable }:
let
  collector = net.metricsCollector;
  seg = net.segments.servers;
  store = "http://127.0.0.1:${toString net.ports.victoriaLogs}";
  insert = "http://${net.hosts.${collector}.ip}:${toString net.ports.victoriaLogsInsert}";
  query = "http://127.0.0.1:${toString net.ports.victoriaLogsQuery}";

  # What vmauth answers a path that matches no route.
  refusedStatus = 400;

  node =
    hostname: ip: extra:
    { pkgs, ... }:
    {
      _module.args.hostname = hostname;
      imports = [ ../modules/journal-upload.nix ] ++ extra;
      virtualisation.interfaces.end0.vlan = 1;
      environment.systemPackages = [ pkgs.curl ];
      networking = {
        useDHCP = false;
        interfaces.end0.ipv4.addresses = [
          {
            address = ip;
            inherit (seg) prefixLength;
          }
        ];
      };
    };
in
{
  name = "journal-upload";

  node.specialArgs = { inherit net unstable; };

  nodes = {
    ${collector} = {
      imports = [
        (node collector net.hosts.${collector}.ip [ ../modules/logs.nix ])
      ];
      # The store stops taking lines below `-storage.minFreeDiskSpaceBytes`.
      # The image is sparse, so this costs no space.
      virtualisation.diskSize = 60 * 1024;
    };
    core4 = node "core4" net.hosts.core4.ip [ ];
    gate = {
      imports = [ (node "gate" seg.gateway [ ]) ];
      # A stand-in for Kea, in the namespace hosts/gate/routing.nix gives it.
      systemd.services.kea-standin = {
        serviceConfig = {
          Type = "oneshot";
          LogNamespace = "kea";
          ExecStart = "/run/current-system/sw/bin/echo journal-upload-test-kea";
        };
      };
    };
  };

  testScript = ''
    import shlex

    def select(phrase, base="${store}"):
        query = shlex.quote('query="' + phrase + '"')
        return f"curl -sf {base}/select/logsql/query --data-urlencode {query}"

    def found(phrase):
        """The store's lines holding `phrase`, as JSON lines."""
        return ${collector}.succeed(select(phrase))

    def wait_found(phrase, host):
        hostname = shlex.quote('"_HOSTNAME":"' + host + '"')
        ${collector}.wait_until_succeeds(f"{select(phrase)} | grep -F {hostname}", timeout=120)

    def status(machine, url, method="POST"):
        return int(machine.succeed(
            f"curl -s --path-as-is -o /dev/null -w '%{{http_code}}' -X {method} {shlex.quote(url)}"
        ))

    start_all()
    ${collector}.wait_for_unit("victorialogs.service")
    ${collector}.wait_for_unit("vmauth-logs.service")
    ${collector}.wait_for_unit("vmauth-logs-query.service")
    ${collector}.wait_for_open_port(${toString net.ports.victoriaLogsQuery}, "127.0.0.1")
    # From a source: vmauth-logs refuses core5's own address.
    core4.wait_until_succeeds("curl -s -o /dev/null --max-time 2 ${insert}/", timeout=60)

    with subtest("each host's logger line is found on the collector"):
        for name, machine in [("${collector}", ${collector}), ("core4", core4), ("gate", gate)]:
            machine.wait_for_unit("systemd-journal-upload.service", timeout=300)
            machine.succeed(f"logger journal-upload-test-{name}")
            wait_found(f"journal-upload-test-{name}", name)

    with subtest("a unit in gate's Kea namespace stays on gate"):
        gate.succeed("systemctl start kea-standin")
        gate.wait_until_succeeds("journalctl --namespace=kea -u kea-standin | grep -q journal-upload-test-kea", timeout=30)
        gate.succeed("logger journal-upload-test-after-kea")
        wait_found("journal-upload-test-after-kea", "gate")
        assert "journal-upload-test-kea" not in found("journal-upload-test-kea"), "Kea's namespace was uploaded"

    with subtest("an upload's first start sends nothing older than itself"):
        core4.succeed("systemctl stop systemd-journal-upload")
        core4.succeed("rm /var/lib/systemd/journal-upload/state")
        core4.succeed("logger journal-upload-test-history")
        core4.succeed("systemctl start systemd-journal-upload")
        core4.succeed("logger journal-upload-test-fresh")
        wait_found("journal-upload-test-fresh", "core4")
        assert "journal-upload-test-history" not in found("journal-upload-test-history"), "history was uploaded"

    with subtest("core4's upload retries without a link and never enters failed"):
        unit = "systemd-journal-upload"
        # The failed state is momentary even without RestartMode=direct, and
        # `Failed with result` is logged either way, so read the transition.
        core4.succeed("systemd-analyze log-level debug")
        core4.succeed(f"systemctl stop {unit}")
        since = core4.succeed("date +%s").strip()
        core4.send_monitor_command("set_link vlan1 off")
        core4.wait_until_succeeds("grep -qx 0 /sys/class/net/end0/carrier", timeout=10)
        core4.succeed(f"systemctl start --no-block {unit}")
        restarts = int(core4.succeed(f"systemctl show -P NRestarts {unit}"))
        core4.sleep(5)
        core4.send_monitor_command("set_link vlan1 on")
        core4.wait_until_succeeds(f"[ $(systemctl show -P NRestarts {unit}) -gt {restarts} ]", timeout=30)
        core4.wait_for_unit(f"{unit}.service", timeout=60)
        core4.succeed("logger journal-upload-test-relinked")
        wait_found("journal-upload-test-relinked", "core4")
        core4.succeed("systemd-analyze log-level info")
        changes = core4.succeed(f"journalctl -u {unit} --since @{since} -o cat | grep -F 'Changed ' || true")
        assert " -> auto-restart" in changes, changes
        assert " -> failed" not in changes, changes

    with subtest("a client reaches the upload path alone"):
        for path in [
            "/select/logsql/query?query=*",
            "/select/logsql/hits?query=*",
            "/select/vmui/",
            "/delete/run_task?filter=*",
            "/insert/jsonline",
            "/insert/loki/api/v1/push",
            "/insert/elasticsearch/_bulk",
            "/internal/insert",
            "/internal/force_merge",
            "/internal/partition/list",
            "/flags",
            "/metrics",
            # vmauth cleans the path before it matches a route.
            "/insert/journald/upload/../../../select/logsql/query?query=*",
            "/insert/journald/upload/%2e%2e/%2e%2e/%2e%2e/select/logsql/query?query=*",
        ]:
            code = status(core4, f"${insert}{path}")
            assert code == ${toString refusedStatus}, f"{path} through vmauth: {code}"
        core4.fail("curl -s --max-time 5 http://${net.hosts.${collector}.ip}:${toString net.ports.victoriaLogs}/")

    with subtest("on loopback, delete is off and admin endpoints take the key"):
        code = status(${collector}, "${store}/delete/run_task?filter=*")
        assert not 200 <= code < 300, f"delete: {code}"
        assert "journal-upload-test-core4" in found("journal-upload-test-core4")
        key = ${collector}.succeed("cat /run/victorialogs-admin-key").strip()
        for path in ["/internal/force_flush", "/internal/force_merge", "/flags", "/debug/pprof/cmdline"]:
            assert status(${collector}, f"${store}{path}") == 401, f"{path} without the key"
            code = status(${collector}, f"${store}{path}?authKey={key}")
            assert 200 <= code < 300, f"{path} with the key: {code}"

    with subtest("the query vmauth passes reads alone"):
        out = ${collector}.succeed(select("journal-upload-test-core4", "${query}"))
        assert "journal-upload-test-core4" in out, out
        assert status(${collector}, "${query}/select/vmui/", "GET") == 200
        for method, path in [
            ("POST", "/insert/jsonline"),
            ("POST", "/insert/journald/upload"),
            ("GET", "/delete/run_task?filter=*"),
            ("GET", "/internal/force_merge"),
            ("GET", "/flags"),
            ("POST", "/select/logsql/../../insert/jsonline"),
        ]:
            code = status(${collector}, f"${query}{path}", method)
            assert code == ${toString refusedStatus}, f"{method} {path} through the query vmauth: {code}"
  '';
}
