# The Pis' deploy login, end to end in one VM: the forced command over ssh, each
# verb's request reaching root through its path unit, and the refusals.
#
# `nix build .#checks.x86_64-linux.deploy-agent`. It needs KVM, which forge's
# daemon has; CI's vm-tests job runs it on pull requests.
#
# nixos-upgrade.service is a stand-in: the real one fetches main from GitHub,
# which a VM cannot reach. What is under test is everything around it. Files
# under /run/test steer the stand-in: `fail` makes it fail, `slow` keeps it
# running until `slow` is removed. The reboot itself is not exercised, since
# the driver would see the VM go; its refusal during an upgrade is.
{ }:
{
  name = "deploy-agent";

  nodes.machine =
    { lib, pkgs, ... }:
    let
      keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
    in
    {
      _module.args.deployPubKeys = [ keys.snakeOilPublicKey ];

      imports = [
        ../modules/deploy-agent.nix
        ../modules/host-status.nix
      ];

      # As on the Pis, where an account nothing gives a password is locked.
      users.mutableUsers = false;

      services.openssh.enable = true;
      security.sudo.execWheelOnly = true;

      # The real unit's settings, the timer and the module's hold condition
      # among them, with a stand-in script. The timer never fires.
      system.autoUpgrade = {
        enable = true;
        dates = "2099-01-01";
      };
      systemd.services.nixos-upgrade.script = lib.mkForce ''
        echo "stand-in upgrade running"
        while [ -e /run/test/slow ]; do sleep 1; done
        if [ -e /run/test/fail ]; then
          echo "stand-in upgrade failed on purpose"
          exit 1
        fi
        date +%s%N >> /run/test/upgrades
      '';
      systemd.tmpfiles.rules = [ "d /run/test 0755 root root -" ];

      environment.etc."deploy-key" = {
        source = keys.snakeOilPrivateKey;
        mode = "0600";
      };
    };

  testScript = ''
    import shlex

    def agent(verb, code=0):
        """Runs `verb` on the deploy login and returns its output."""
        cmd = (
            "ssh -T -i /etc/deploy-key -o StrictHostKeyChecking=no "
            f"-o BatchMode=yes deploy@localhost {shlex.quote(verb)} </dev/null 2>&1"
        )
        status, out = machine.execute(cmd)
        assert status == code, f"{verb!r}: exit {status}, wanted {code}:\n{out}"
        return out

    def upgrades():
        status, out = machine.execute("wc -l < /run/test/upgrades")
        return int(out) if status == 0 else 0

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("sshd.service")

    # A test VM boots its system without a profile. Give it one that matches,
    # so `staged` has the two sides the Pis do.
    machine.succeed("mkdir -p /nix/var/nix/profiles && ln -sfn \"$(readlink -f /run/booted-system)\" /nix/var/nix/profiles/system")

    with subtest("the login runs deploy-agent and nothing else"):
        assert "usage:" in agent("id", code=64)
        assert "usage:" in agent("bash -c id", code=64)
        assert "usage:" in agent("", code=64)

    with subtest("status"):
        out = agent("status")
        for line in ["staged\tno", "hold\tno", "upgrade\t"]:
            assert line in out, f"no {line!r} in:\n{out}"

    with subtest("a new kernel in the profile reads as staged"):
        machine.succeed(
            "mkdir /tmp/next && cp -a /run/booted-system/. /tmp/next/"
            " && ln -sfn /dev/null /tmp/next/kernel"
            " && ln -sfn /tmp/next /nix/var/nix/profiles/system"
        )
        assert "staged\tyes" in agent("status")
        machine.succeed("ln -sfn \"$(readlink -f /run/booted-system)\" /nix/var/nix/profiles/system")

    with subtest("upgrade starts the unit and waits for it"):
        before = upgrades()
        agent("upgrade")
        assert upgrades() == before + 1

    with subtest("a failed upgrade fails, with its journal"):
        machine.succeed("touch /run/test/fail")
        out = agent("upgrade", code=1)
        assert "stand-in upgrade failed on purpose" in out, out
        machine.succeed("rm /run/test/fail")


    with subtest("an upgrade already running is not waited on"):
        machine.succeed("touch /run/test/slow")
        machine.succeed("systemctl start --no-block nixos-upgrade.service")
        machine.wait_until_succeeds("systemctl show nixos-upgrade.service -p ActiveState --value | grep -qx activating")
        agent("upgrade", code=75)

        # Nor is a reboot taken while it runs. The root side refuses, the
        # agent says so, and the refusal is not left as a failed unit.
        assert "not rebooting" in agent("reboot", code=75)
        machine.fail("systemctl is-failed --quiet deploy-agent-reboot.service")

        machine.succeed("rm /run/test/slow")
        machine.wait_until_succeeds("systemctl show nixos-upgrade.service -p ActiveState --value | grep -qx inactive")

    with subtest("a hold stops the upgrade until released"):
        assert "hold\tyes" in agent("hold")
        assert "hold\tyes" in agent("status")
        before = upgrades()

        # The timer's way in is skipped, not failed, and a switch cannot undo
        # it, since it is a file and not a stopped timer.
        machine.succeed("systemctl restart timers.target")
        machine.succeed("systemctl start nixos-upgrade.service")
        machine.fail("systemctl is-failed --quiet nixos-upgrade.service")
        assert upgrades() == before

        # The deploy login's way in refuses, rather than waiting on a run
        # that will not happen.
        assert "held" in agent("upgrade", code=69)
        assert upgrades() == before

        assert "hold\tno" in agent("release")
        agent("upgrade")
        assert upgrades() == before + 1

    with subtest("the deploy user cannot run sudo"):
        # execWheelOnly, not the lack of a sudoers rule: deploy cannot even
        # execute the binary.
        machine.fail("su -s /bin/sh deploy -c 'test -x /run/wrappers/bin/sudo'")
  '';
}
