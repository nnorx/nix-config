# The alerts' way out of the house, end to end in VMs: vmalert evaluates rules
# that always fire, Alertmanager routes them, and a stub standing in for
# ntfy.sh and hc-ping.com receives what would have left. Each severity reaches
# ntfy with its own priority, the watchdog reaches healthchecks.io and nothing
# else does, the links sent are loopback, and an alert still firing is pushed
# once, through evaluations, a flush of its group and a restart of each
# service.
#
# `nix build .#checks.x86_64-linux.alerting`. It needs KVM, which forge's
# daemon has; CI's vm-tests job runs it on pull requests. About 8 minutes,
# most of it waiting out the production intervals, which this does not shorten.
#
# core5 is modules/alerting.nix itself, with a store of its own. The real rules
# load and find nothing in an empty store; three test rules, one per severity,
# fire from the first evaluation. sops-nix is a stand-in, as in
# ./dns-metrics.nix, and the secrets are test values. The stub answers HTTPS
# under the real names, which core5 resolves to it, with a certificate from a
# CA core5 trusts, so the URLs under test are the ones the module builds.
{ net }:
let
  collector = net.metricsCollector;

  # Test values only: core5's own are in sops.
  topic = "test-topic";
  pingKey = "test-ping-key";

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
      config.sops.placeholder = {
        ntfy-url = "https://ntfy.sh/${topic}";
        healthchecks-ping-key = pingKey;
      };
    };

  hosts = [
    "ntfy.sh"
    "hc-ping.com"
  ];
in
{
  name = "alerting";

  node.specialArgs = {
    inherit net;
    hostname = collector;
  };

  nodes = {
    ${collector} =
      {
        lib,
        nodes,
        pkgs,
        ...
      }:
      {
        imports = [
          sopsStub
          ../modules/alerting.nix
        ];

        services.victoriametrics = {
          enable = true;
          listenAddress = "127.0.0.1:${toString net.ports.victoriaMetrics}";
        };

        services.vmalert.instances."".settings.rule = [
          (pkgs.writeText "test-rules.json" (
            builtins.toJSON {
              groups = [
                {
                  name = "test";
                  rules =
                    map
                      (severity: {
                        alert = "Test${lib.toUpper (lib.substring 0 1 severity)}${lib.substring 1 (-1) severity}";
                        expr = "vector(1)";
                        labels = {
                          inherit severity;
                          instance = "core4";
                        };
                        annotations.summary = "A ${severity} test alert.";
                      })
                      [
                        "critical"
                        "warning"
                        "info"
                      ];
                }
              ];
            }
          ))
        ];

        # baseline.nix's, which the module reads; nothing upgrades here.
        system.autoUpgrade.flake = "github:nnorx/nix-config";
        # It would ask GitHub, which no VM reaches.
        systemd.timers.fleet-main-revision.wantedBy = lib.mkForce [ ];

        networking.hosts.${nodes.internet.networking.primaryIPAddress} = hosts;
        security.pki.certificateFiles = [ "${nodes.internet.services.alert-receiver.certs}/ca.crt" ];
      };

    # ntfy.sh and hc-ping.com, as one HTTPS server that writes down each
    # request.
    internet =
      { lib, pkgs, ... }:
      let
        certs = pkgs.runCommand "alert-receiver-certs" { nativeBuildInputs = [ pkgs.openssl ]; } ''
          mkdir $out
          openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=test-ca \
            -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign \
            -keyout ca.key -out $out/ca.crt
          openssl req -newkey rsa:2048 -nodes -subj /CN=stand-in -keyout $out/server.key -out server.csr
          printf 'subjectAltName=${lib.concatMapStringsSep "," (h: "DNS:${h}") hosts}\n' > ext
          openssl x509 -req -in server.csr -CA $out/ca.crt -CAkey ca.key -CAcreateserial \
            -days 3650 -extfile ext -out $out/server.crt
        '';
        receiver = pkgs.writeScript "alert-receiver" ''
          #!${pkgs.python3.interpreter}
          import json
          import ssl
          from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
          from urllib.parse import parse_qs, urlsplit


          class Handler(BaseHTTPRequestHandler):
              def do_POST(self):
                  body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                  url = urlsplit(self.path)
                  record = {
                      "host": self.headers.get("Host"),
                      "path": url.path,
                      "query": parse_qs(url.query),
                      "body": json.loads(body) if body else None,
                  }
                  with open("/var/lib/alert-receiver/requests.jsonl", "a") as log:
                      log.write(json.dumps(record) + "\n")
                  self.send_response(200)
                  self.end_headers()
                  self.wfile.write(b"OK")


          server = ThreadingHTTPServer(("0.0.0.0", 443), Handler)
          context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
          context.load_cert_chain("${certs}/server.crt", "${certs}/server.key")
          server.socket = context.wrap_socket(server.socket, server_side=True)
          server.serve_forever()
        '';
      in
      {
        options.services.alert-receiver.certs = lib.mkOption {
          type = lib.types.package;
          default = certs;
        };
        config = {
          networking.firewall.allowedTCPPorts = [ 443 ];
          systemd.services.alert-receiver = {
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              ExecStart = receiver;
              StateDirectory = "alert-receiver";
            };
          };
        };
      };
  };

  testScript = ''
    import json
    import time

    collector = ${collector}
    start_all()

    internet.wait_for_unit("alert-receiver.service")
    internet.wait_for_open_port(443)
    for unit in ("victoriametrics", "alertmanager", "vmalert"):
        collector.wait_for_unit(f"{unit}.service")
    for port in (${toString net.ports.vmalert}, ${toString net.ports.alertmanager}):
        collector.wait_for_open_port(port, "127.0.0.1")

    def requests():
        out = internet.succeed("cat /var/lib/alert-receiver/requests.jsonl 2>/dev/null || true")
        return [json.loads(line) for line in out.splitlines() if line.strip()]

    def names(r):
        return sorted({a["labels"]["alertname"] for a in r["body"]["alerts"]})

    def pushes(name=None):
        return [r for r in requests() if r["path"] == "/${topic}" and (name is None or name in names(r))]

    def pings():
        return [r for r in requests() if r["path"] == "/${pingKey}/${collector}-metrics-watchdog"]

    def counts():
        return {name: len(pushes(name)) for name in ("TestCritical", "TestWarning", "TestInfo")}

    with subtest("vmalert and Alertmanager listen on loopback alone, and do not cluster"):
        listening = collector.succeed("ss -ltnuH")
        print(listening)
        for port in ("${toString net.ports.vmalert}", "${toString net.ports.alertmanager}"):
            assert f"127.0.0.1:{port} " in listening, f"nothing on 127.0.0.1:{port}"
            for wildcard in ("0.0.0.0", "*", "[::]"):
                assert f"{wildcard}:{port} " not in listening, f"{port} listens on {wildcard}"
        assert ":9094 " not in listening, "Alertmanager's cluster port is open"

    with subtest("each severity reaches ntfy with its own priority"):
        internet.wait_until_succeeds("grep -q TestInfo /var/lib/alert-receiver/requests.jsonl", timeout=180)
        internet.wait_until_succeeds("grep -q TestCritical /var/lib/alert-receiver/requests.jsonl", timeout=60)
        internet.wait_until_succeeds("grep -q TestWarning /var/lib/alert-receiver/requests.jsonl", timeout=60)
        first = time.monotonic()
        for name, query in (
            ("TestCritical", {"template": ["alertmanager"], "priority": ["high"]}),
            ("TestWarning", {"template": ["alertmanager"]}),
            ("TestInfo", {"template": ["alertmanager"], "priority": ["low"]}),
        ):
            got = pushes(name)
            assert len(got) == 1, f"{name}: {len(got)} pushes"
            assert got[0]["host"] == "ntfy.sh", got[0]["host"]
            assert got[0]["query"] == query, f"{name}: {got[0]['query']}"
            # Grouped by alert name, so each push is one alert.
            assert names(got[0]) == [name], names(got[0])
        # The real rules, against an empty store, find nothing.
        assert {n for r in pushes() for n in names(r)} == {"TestCritical", "TestWarning", "TestInfo"}, [names(r) for r in pushes()]

    with subtest("the watchdog reaches healthchecks.io, and only it does"):
        internet.wait_until_succeeds("grep -q '/${pingKey}/' /var/lib/alert-receiver/requests.jsonl", timeout=120)
        ping = pings()[0]
        assert ping["host"] == "hc-ping.com", ping["host"]
        assert ping["query"] == {"create": ["1"]}, ping["query"]
        assert names(ping) == ["Watchdog"], names(ping)
        assert not pushes("Watchdog"), "the watchdog reached ntfy"
        assert all(names(r) == ["Watchdog"] for r in pings())

    with subtest("the links sent are loopback, not the host's name"):
        for r in requests():
            body = r["body"]
            assert body["externalURL"] == "http://127.0.0.1:${toString net.ports.alertmanager}", body["externalURL"]
            for a in body["alerts"]:
                assert a["generatorURL"].startswith("http://127.0.0.1:${toString net.ports.vmalert}/"), a["generatorURL"]

    with subtest("an alert still firing is pushed once"):
        # Each service restarted while the alerts fire: vmalert reads their
        # state back, and Alertmanager its log of what it sent.
        collector.succeed("systemctl restart vmalert.service")
        collector.wait_for_unit("vmalert.service")
        collector.succeed("systemctl restart alertmanager.service")
        collector.wait_for_unit("alertmanager.service")
        # Past a second watchdog ping, which is Alertmanager repeating what
        # nothing resolved, and past the first flush of the test alerts'
        # groups, 5 minutes after their first push: a dozen evaluations, and
        # each group asked again whether to send.
        internet.wait_until_succeeds("test $(grep -c '/${pingKey}/' /var/lib/alert-receiver/requests.jsonl) -ge 2", timeout=480)
        remaining = first + 5 * 60 + 60 - time.monotonic()
        if remaining > 0:
            time.sleep(remaining)
        assert counts() == {"TestCritical": 1, "TestWarning": 1, "TestInfo": 1}, counts()
  '';
}
