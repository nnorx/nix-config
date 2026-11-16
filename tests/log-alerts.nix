# The security alerts in modules/log-alert-rules.nix, end to end in VMs: core4
# writes each event's journal line itself, a refused sudo password, a fail2ban
# ban and an SSH login as its own user, its upload carries the line to
# VictoriaLogs on core5, and vmalert-logs raises the alert in Alertmanager,
# routed to the receiver of its priority. A login as diag raises nothing, nor
# does fail2ban restoring a ban at start, and no label or annotation carries an
# address. JournalSilent's query names core4 while its upload is stopped, and
# no host while both upload.
#
# `nix build .#checks.x86_64-linux.log-alerts`. It needs KVM, which forge's
# daemon has; CI's vm-tests job runs it on pull requests.
#
# core4 takes modules/ssh.nix, modules/diag-login.nix and modules/fail2ban.nix
# as every server does, with nixpkgs' stand-in keys. Alertmanager is the real
# one and is asked through its API; tests/alerting.nix follows a push out of
# the house. sops-nix is a stand-in, as there.
{ net, unstable }:
let
  collector = net.metricsCollector;
  seg = net.segments.servers;
  core4Ip = net.hosts.core4.ip;
  store = "http://127.0.0.1:${toString net.ports.victoriaLogs}";
  alertmanager = "http://127.0.0.1:${toString net.ports.alertmanager}";

  # Each rule's query, to run against the store directly.
  exprs = builtins.listToAttrs (
    map (r: {
      name = r.alert;
      value = r.expr;
    }) (builtins.concatMap (g: g.rules) (import ../modules/log-alert-rules.nix).groups)
  );

  # JournalSilent's query over a minute, as 30 is too long to wait here.
  silent = builtins.replaceStrings [ "_time:30m" ] [ "_time:1m" ] exprs.JournalSilent;

  # A banned address from TEST-NET-1, which no test machine holds.
  banned = "192.0.2.10";

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
        ntfy-url = "https://ntfy.sh/test-topic";
        healthchecks-ping-key = "test-ping-key";
      };
    };

  onServers = ip: {
    virtualisation.interfaces.end0.vlan = 1;
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
  name = "log-alerts";

  node.specialArgs = { inherit net unstable; };

  nodes = {
    ${collector} =
      { lib, pkgs, ... }:
      let
        keys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;
      in
      {
        _module.args.hostname = collector;
        imports = [
          sopsStub
          (onServers net.hosts.${collector}.ip)
          ../modules/alerting.nix
          ../modules/logs.nix
          ../modules/journal-upload.nix
        ];

        services.victoriametrics = {
          enable = true;
          listenAddress = "127.0.0.1:${toString net.ports.victoriaMetricsStore}";
        };
        # As tests/alerting.nix: nothing upgrades here, nor asks GitHub.
        system.autoUpgrade.flake = "github:nnorx/nix-config";
        systemd.timers.fleet-main-revision.wantedBy = lib.mkForce [ ];

        # The store stops taking lines below `-storage.minFreeDiskSpaceBytes`.
        # The image is sparse, so this costs no space.
        virtualisation.diskSize = 60 * 1024;

        environment.systemPackages = [ pkgs.curl ];
        environment.etc."admin-key" = {
          source = keys.snakeOilPrivateKey;
          mode = "0600";
        };
        environment.etc."diag-key" = {
          source = keys.snakeOilEd25519PrivateKey;
          mode = "0600";
        };
      };

    core4 =
      { pkgs, ... }:
      let
        keys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;
      in
      {
        _module.args = {
          hostname = "core4";
          sshPubKeys = [ keys.snakeOilPublicKey ];
          diagPubKeys = [ keys.snakeOilEd25519PublicKey ];
        };
        imports = [
          (onServers core4Ip)
          ../modules/ssh.nix
          ../modules/diag-login.nix
          ../modules/fail2ban.nix
          ../modules/journal-upload.nix
        ];
        # modules/firewall.nix's, for this one interface.
        networking.firewall.interfaces.end0.allowedTCPPorts = [ 22 ];

        # As on the servers (modules/baseline.nix, hosts/common), with a
        # stand-in password.
        users.mutableUsers = false;
        users.users.core4 = {
          isNormalUser = true;
          extraGroups = [ "wheel" ];
          password = "stand-in";
        };
        security.sudo = {
          execWheelOnly = true;
          wheelNeedsPassword = true;
        };
      };
  };

  testScript = ''
    import json
    import shlex
    import time

    collector = ${collector}

    def curl(*args):
        return collector.succeed("curl -sf " + " ".join(shlex.quote(a) for a in args))

    def run(expr):
        out = curl("${store}/select/logsql/stats_query", "--data-urlencode", "query=" + expr)
        return json.loads(out)["data"]["result"]

    def stats(alert):
        """The rule's own query, run against the store now."""
        return run(EXPRS[alert])

    def silent():
        rows = run(SILENT)
        print(rows)
        return rows

    def wait_stored(phrase, host="core4"):
        query = shlex.quote(f'query=_HOSTNAME:={host} "{phrase}"')
        collector.wait_until_succeeds(
            f"curl -sf ${store}/select/logsql/query --data-urlencode {query} | grep -q .", timeout=120
        )

    def alerts(name):
        out = curl("-G", "${alertmanager}/api/v2/alerts", "--data-urlencode", f'filter=alertname="{name}"')
        return json.loads(out)

    def wait_alert(name, severity, receiver, summary):
        collector.wait_until_succeeds(
            f"curl -sfG ${alertmanager}/api/v2/alerts --data-urlencode 'filter=alertname=\"{name}\"' | grep -q {name}",
            timeout=300,
        )
        [a] = alerts(name)
        print(json.dumps(a, indent=2))
        labels = a["labels"]
        assert labels["instance"] == "core4", labels
        assert labels["severity"] == severity, labels
        assert set(labels) <= {"alertname", "alertgroup", "instance", "severity", "stats_result"}, labels
        assert a["annotations"]["summary"] == summary, a["annotations"]
        assert [r["name"] for r in a["receivers"]] == [receiver], a["receivers"]
        text = json.dumps({"labels": labels, "annotations": a["annotations"]})
        for address in ("${core4Ip}", "${net.hosts.${collector}.ip}", "${banned}"):
            assert address not in text, f"{address} in {text}"

    def ssh(key, login):
        collector.succeed(
            f"ssh -i {key} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o BatchMode=yes "
            f"{login}@${core4Ip} true </dev/null"
        )

    def fresh(machine, phrase):
        """A line from the machine, once it is in the store."""
        machine.succeed(f"logger -t journal-silent '{phrase}'")
        wait_stored(phrase, machine.name)

    EXPRS = json.loads(${builtins.toJSON (builtins.toJSON exprs)})
    SILENT = ${builtins.toJSON silent}
    assert SILENT != EXPRS["JournalSilent"]

    start_all()
    for unit in ("victorialogs", "vmauth-logs", "victoriametrics", "alertmanager", "vmalert-logs"):
        collector.wait_for_unit(f"{unit}.service")
    for unit in ("sshd", "fail2ban", "systemd-journal-upload"):
        core4.wait_for_unit(f"{unit}.service")
    core4.wait_until_succeeds("fail2ban-client status sshd", timeout=60)
    collector.wait_until_succeeds("ssh-keyscan ${core4Ip} | grep -q ssh-ed25519", timeout=60)

    with subtest("a login as diag is stored and raises nothing"):
        ssh("/etc/diag-key", "diag")
        wait_stored("Accepted publickey for diag")
        assert stats("HostUserLogin") == [], stats("HostUserLogin")

    with subtest("a refused sudo password is SudoFailed, at high priority"):
        core4.fail("su core4 -c 'echo wrong | sudo -S -k true'")
        print(core4.succeed("journalctl -t sudo --no-pager"))
        wait_alert("SudoFailed", "critical", "critical", "sudo refused a password on core4.")
        # The same evaluation saw diag's login.
        assert alerts("HostUserLogin") == [], alerts("HostUserLogin")

    with subtest("a fail2ban ban is Fail2banBan, at default priority"):
        core4.succeed("fail2ban-client set sshd banip ${banned}")
        print(core4.succeed("journalctl -u fail2ban --no-pager | grep -i ban"))
        wait_alert("Fail2banBan", "warning", "warning", "fail2ban banned an address on core4.")

    with subtest("fail2ban restoring a ban at start is not a new one"):
        core4.succeed("systemctl restart fail2ban")
        wait_stored("Restore Ban")
        [r] = stats("Fail2banBan")
        assert r["value"][1] == "1", r

    with subtest("a login as the host's own user is HostUserLogin, at low priority"):
        ssh("/etc/admin-key", "core4")
        print(core4.succeed("journalctl -u sshd --no-pager | grep Accepted"))
        wait_alert("HostUserLogin", "info", "info", "Someone logged in to core4 as its own user over SSH.")

    with subtest("a host uploading is not JournalSilent"):
        fresh(core4, "uploading")
        fresh(collector, "uploading")
        assert [r for r in silent() if r["metric"]["instance"] == "core4"] == []

    with subtest("a host whose upload stops is JournalSilent"):
        core4.succeed("systemctl stop systemd-journal-upload")
        time.sleep(70)
        fresh(collector, "after the stop")
        [r] = silent()
        assert r["metric"]["instance"] == "core4", r
        assert r["value"][1] == "0", r

    with subtest("its upload back, it is not"):
        core4.succeed("systemctl start systemd-journal-upload")
        fresh(core4, "after the start")
        fresh(collector, "after the start")
        assert silent() == []
  '';
}
