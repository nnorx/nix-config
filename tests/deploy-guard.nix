# gate's automatic rollback in one VM: arm's checks, confirm, an expired or
# unreadable arm, and an unconfirmed one switching the profile back and
# rebooting. A test VM has no system profile, so the script makes two
# generations by hand, the running system and a specialisation. With no
# bootloader the rollback shows in the profile link, not in what boots next.
{ }:
{
  name = "deploy-guard";

  nodes.machine = {
    imports = [ ../modules/deploy-guard.nix ];
    boot.loader.grub.enable = false;
    specialisation.next.configuration = {
      environment.etc."deploy-guard-test".text = "next";
    };
  };

  testScript = ''
    armed = "/var/lib/deploy-guard/armed"
    profiles = "/nix/var/nix/profiles"

    def profile():
        return machine.succeed(f"readlink {profiles}/system").strip()

    def mark(minutes, gen, age_s=0):
        machine.succeed(
            f"mkdir -p /var/lib/deploy-guard"
            f" && echo \"{minutes} {gen} $(($(date +%s) - {age_s}))\" > {armed}"
        )

    def fresh():
        machine.succeed(f"rm -f {armed} && ln -sfn system-2-link {profiles}/system")

    # The unit's latest run, so one subtest's lines do not satisfy the next.
    journal = (
        "journalctl -b -o cat"
        " _SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value deploy-guard)"
    )

    def wait_log(text):
        machine.wait_until_succeeds(f"{journal} | grep -qF '{text}'")

    machine.wait_for_unit("multi-user.target")
    machine.succeed(
        f"mkdir -p {profiles}"
        f" && ln -sfn \"$(readlink -f /run/current-system/specialisation/next)\" {profiles}/system-1-link"
        f" && ln -sfn \"$(readlink -f /run/current-system)\" {profiles}/system-2-link"
    )
    fresh()
    assert profile() == "system-2-link"

    with subtest("arm refuses bad minutes"):
        fresh()
        for minutes in ["0", "15m", "61", "abc"]:
            status, out = machine.execute(f"deploy-guard arm {minutes} 2>&1")
            assert status == 64, f"arm {minutes}: exit {status}, wanted 64:\n{out}"
        machine.succeed(f"test ! -e {armed}")

    with subtest("arm records the running generation"):
        fresh()
        machine.succeed("deploy-guard arm 1")
        fields = machine.succeed(f"cat {armed}").split()
        assert fields[:2] == ["1", "2"], fields
        machine.succeed(f"rm {armed}")

    with subtest("confirm cancels a countdown"):
        fresh()
        mark(1, 1)
        machine.succeed("systemctl start deploy-guard")
        wait_log("rolling back to generation 1 in 1 minutes")
        machine.succeed("deploy-guard confirm")
        machine.fail("systemctl is-active --quiet deploy-guard")
        machine.succeed(f"test ! -e {armed}")
        machine.sleep(75)
        assert profile() == "system-2-link", profile()

    with subtest("an expired arm is ignored"):
        fresh()
        mark(1, 1, age_s=7 * 3600)
        machine.succeed("systemctl start deploy-guard")
        machine.wait_until_fails("systemctl is-active --quiet deploy-guard")
        wait_log("ignoring an arm")
        machine.succeed(f"test ! -e {armed}")
        assert profile() == "system-2-link", profile()

    with subtest("bad minutes count down the default"):
        fresh()
        mark("abc", 1)
        machine.succeed("systemctl start deploy-guard")
        wait_log("counting down the default 15")
        machine.succeed("deploy-guard confirm")
        machine.fail("systemctl is-active --quiet deploy-guard")
        assert profile() == "system-2-link", profile()

    # Last, since it reboots: the driver's QEMU runs with -no-reboot, so the
    # guest's reboot powers it off and start() boots the same disk again.
    with subtest("an unconfirmed arm rolls back and reboots"):
        fresh()
        mark(1, 1)
        machine.succeed("systemctl start deploy-guard")
        machine.wait_for_shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")
        assert profile() == "system-1-link", profile()
        machine.succeed(f"test ! -e {armed}")
        machine.fail("journalctl -u deploy-guard -b | grep -q 'rolling back'")
  '';
}
