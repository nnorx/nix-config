# The diag login, from a client over ssh as fleet-ssh reaches it:
# host-status in full, no sudo, the journal group and not wheel, no pty, keys
# only from the declared lists, and the host's own user still let in beside it.
#
# `nix build .#checks.x86_64-linux.diag-login`. It needs KVM, which forge's
# daemon has; CI's vm-tests job runs it on pull requests.
#
# The server takes modules/ssh.nix and modules/diag-login.nix as every fleet
# host does, with stand-in keys, so AllowUsers is the merged list the hosts
# get. nixos-upgrade.service is a stand-in, as in tests/deploy-agent.nix, run
# once so host-status has an upgrade in the journal to report.
{ net }:
let
  user = "server";
in
{
  name = "diag-login";

  nodes.server =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      keys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;
    in
    {
      _module.args = {
        inherit net;
        hostname = user;
        sshPubKeys = [ keys.snakeOilPublicKey ];
        diagPubKeys = [ keys.snakeOilEd25519PublicKey ];
      };

      imports = [
        ../modules/ssh.nix
        ../modules/diag-login.nix
        ../modules/host-status.nix
      ];

      # A host with no `ip` in lib/net.nix binds its own address, as gate
      # does, and opens the port itself, as modules/firewall.nix would.
      services.openssh.listenAddresses = [ { addr = config.networking.primaryIPAddress; } ];
      networking.firewall.allowedTCPPorts = config.services.openssh.ports;

      # As on the servers: the host's own user in wheel, accounts with no
      # password locked, and sudo for wheel alone (modules/baseline.nix).
      users.mutableUsers = false;
      users.users.${user} = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
      };
      security.sudo.execWheelOnly = true;

      system.autoUpgrade = {
        enable = true;
        dates = "2099-01-01";
      };
      systemd.services.nixos-upgrade.script = lib.mkForce ''
        echo "stand-in upgrade"
      '';
    };

  nodes.client =
    { pkgs, ... }:
    let
      keys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;
    in
    {
      environment.etc."diag-key" = {
        source = keys.snakeOilEd25519PrivateKey;
        mode = "0600";
      };
      environment.etc."admin-key" = {
        source = keys.snakeOilPrivateKey;
        mode = "0600";
      };
    };

  testScript =
    { nodes, ... }:
    let
      # sshd binds this address alone, as on the fleet, and the name `server`
      # resolves to its IPv6 address first.
      address = nodes.server.networking.primaryIPAddress;
    in
    ''
      import shlex

      def ssh(key, login, command, code=0, flags=""):
          """Runs `command` on the server as `login` with `key`, and returns its
          output. `code=None` wants any failure."""
          cmd = (
              f"ssh {flags} -i {key} -o IdentitiesOnly=yes -o IdentityAgent=none "
              "-o StrictHostKeyChecking=no -o BatchMode=yes "
              f"{login}@${address} {shlex.quote(command)} </dev/null 2>&1"
          )
          status, out = client.execute(cmd)
          if code is None:
              assert status != 0, f"{login} {command!r}: succeeded, wanted a failure:\n{out}"
              return out
          assert status == code, f"{login} {command!r}: exit {status}, wanted {code}:\n{out}"
          return out

      def diag(command, code=0, flags=""):
          return ssh("/etc/diag-key", "diag", command, code, flags)

      start_all()
      server.wait_for_unit("sshd.service")
      client.wait_for_unit("network.target")
      client.wait_until_succeeds("ssh-keyscan ${address} | grep -q ssh-ed25519", timeout=60)

      server.succeed("systemctl start nixos-upgrade.service")

      with subtest("host-status as diag prints every field"):
          out = diag("host-status")
          for key in ["revision", "root", "failed"]:
              assert f"\n{key}\t" in f"\n{out}", f"no {key} line in:\n{out}"
          # From the journal, which diag reads through systemd-journal.
          assert "\nupgrade\tsuccess " in out, f"no successful upgrade in:\n{out}"

      with subtest("diag is in systemd-journal and not in wheel"):
          groups = diag("id -nG").split()
          assert "systemd-journal" in groups, groups
          assert "wheel" not in groups, groups

      with subtest("diag has no sudo"):
          # execWheelOnly: diag cannot even execute the binary.
          diag("test -x /run/wrappers/bin/sudo", code=1)
          diag("sudo -n true", code=None)

      with subtest("restrict: every key, and no forwarding"):
          keys = server.succeed("grep . /etc/ssh/authorized_keys.d/diag").splitlines()
          assert keys and all(k.startswith("restrict ") for k in keys), keys
          # sshd allows forwarding by default, so this refusal is restrict's.
          out = diag("true", code=255, flags="-o ExitOnForwardFailure=yes -R 0:localhost:1")
          assert "forwarding failed" in out, out

      with subtest("sshd reads keys only from the declared lists"):
          files = server.succeed("sshd -T -f /etc/ssh/sshd_config | grep -i '^authorizedkeysfile'")
          assert files.split()[1:] == ["/etc/ssh/authorized_keys.d/%u"], files

      with subtest("a key in diag's own authorized_keys is refused"):
          client.succeed("ssh-keygen -q -t ed25519 -N ''' -f /root/planted")
          planted = client.succeed("cat /root/planted.pub").strip()
          server.succeed(
              "install -d -m 700 -o diag -g users /home/diag/.ssh"
              f" && echo {shlex.quote(planted)} > /home/diag/.ssh/authorized_keys"
              " && chown diag:users /home/diag/.ssh/authorized_keys"
              " && chmod 600 /home/diag/.ssh/authorized_keys"
          )
          out = ssh("/root/planted", "diag", "true", code=255)
          assert "Permission denied" in out, out

      with subtest("the host's own user still logs in with its key"):
          assert ssh("/etc/admin-key", "${user}", "id -un").strip() == "${user}"

      with subtest("each key opens only its own login"):
          ssh("/etc/diag-key", "${user}", "true", code=255)
          ssh("/etc/admin-key", "diag", "true", code=255)
    '';
}
