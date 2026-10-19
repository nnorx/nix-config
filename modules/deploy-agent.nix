# A `deploy` login on each Pi that can ask for exactly four things: tonight's
# upgrade now, a reboot, and holding or releasing the upgrade. forge's
# fleet-deploy uses it to deploy main by day, host by host, without the sudo
# password.
#
# "Deploy now" means starting nixos-upgrade.service, the unit the timer starts
# every night, with its flags and its substitute-or-fail rule. A daytime deploy
# exercises the path that runs overnight, rather than `nrs`, which differs from
# it and would compile on the host where the upgrade fails fast. What gets
# deployed is fixed by the unit, not by the caller: `main` on GitHub.
#
# The login is a forced command. Its key, from lib/deploy-keys.nix, runs
# `deploy-agent <verb>` and nothing else: no shell, no pty, no forwarding. The
# agent runs as `deploy`, which is not in wheel, so it has no sudo either
# (`security.sudo.execWheelOnly`). It asks for privileged work by writing an
# empty file under /run/deploy-agent, which only it can write, and a path unit
# per file starts one fixed unit as root. Nothing running as root reads
# anything the caller sends, and polkit, which the Pis do not run, is not
# needed. A stolen deploy key can deploy main early, reboot a Pi when nothing
# is running that a reboot would cut off, or hold its upgrades.
#
# fleet-ssh logs in as `diag` (modules/diag-login.nix) with its own key, so it
# cannot reach this login, and deploying stays Nick's.
#
# The upgrade keeps its own rules. Outside the reboot window in
# modules/baseline.nix, a change to the kernel, its modules or the initrd is
# staged for the next boot and nothing is switched, so `status` reports
# `staged yes` and the caller decides whether to ask for `reboot`.
#
# Exit codes, for fleet-deploy: 0 done, 1 failed, 64 not a verb, 69 the
# upgrade is held, 75 busy (an upgrade, or what a reboot would cut off, is
# running) and worth asking again later.
{
  config,
  lib,
  pkgs,
  deployPubKeys,
  ...
}:
let
  requests = "/run/deploy-agent";

  # A hold is a file the upgrade checks, not a stopped timer. Every switch
  # starts timers.target, and with it a stopped timer, so a stopped timer is
  # undone by the next deploy, the daytime upgrade's own switch included. The
  # file stays until `release`, across switches and reboots.
  #
  # A held night skips the upgrade, and the upgrade's heartbeat
  # (modules/alerts.nix) goes silent with it, so healthchecks.io reports a
  # forgotten hold the next day.
  holdFlag = "/var/lib/deploy-agent/hold";

  # Each verb that needs root, and the unit its request file starts.
  units = {
    upgrade = "nixos-upgrade.service";
    reboot = "deploy-agent-reboot.service";
    hold = "deploy-agent-hold.service";
    release = "deploy-agent-release.service";
  };

  # What a reboot must not cut off. The upgrade could be stopped mid-switch.
  # The off-box pushes are scheduled after the nightly reboot window so that
  # no reboot lands on one (modules/offbox-push.nix), and a daytime reboot
  # would bypass that.
  rebootBlockers = [
    "nixos-upgrade.service"
  ]
  ++ map (job: "${job}.service") (lib.attrNames (config.offboxPush or { }));

  # The root side checks rather than trusting the agent to have. A refusal
  # exits 75, which the unit counts as success, so the agent can tell it apart
  # and a refused reboot does not sit in host-status as a failed unit.
  rebootUnlessBusy = pkgs.writeShellScript "deploy-agent-reboot" ''
    for unit in ${lib.escapeShellArgs rebootBlockers}; do
      state=$(${pkgs.systemd}/bin/systemctl show "$unit" -p ActiveState --value)
      case "$state" in
        inactive | failed) ;;
        *)
          echo "deploy-agent: not rebooting, $unit is $state"
          exit 75
          ;;
      esac
    done
    exec ${pkgs.systemd}/bin/systemctl reboot
  '';

  agent = pkgs.writeShellApplication {
    name = "deploy-agent";
    runtimeInputs = with pkgs; [
      coreutils
      systemd
    ];
    text = ''
      requests=${requests}
      hold_flag=${holdFlag}

      # The upgrade unit decides to reboot on the same three links: what booted
      # against what the profile, the next boot, holds.
      staged() {
        for f in kernel initrd kernel-modules; do
          if [ "$(readlink "/run/booted-system/$f")" != "$(readlink "/nix/var/nix/profiles/system/$f")" ]; then
            echo yes
            return
          fi
        done
        echo no
      }

      held() { if [ -e "$hold_flag" ]; then echo yes; else echo no; fi; }

      # host-status's lines, then what only a deploy asks: the revision the
      # next boot runs, which differs from the running one while a kernel is
      # staged, and whether upgrades are held.
      status() {
        /run/current-system/sw/bin/host-status
        printf 'next-boot\t%s\n' "$(/nix/var/nix/profiles/system/sw/bin/nixos-version --configuration-revision 2>/dev/null || echo unknown)"
        printf 'staged\t%s\n' "$(staged)"
        printf 'hold\t%s\n' "$(held)"
      }

      # One property's value from `systemctl show` output. It prints properties
      # in its own order, not the order they were asked for, so each is found
      # by name.
      field() {
        local line
        while IFS= read -r line; do
          case "$line" in
            "$1="*) printf '%s\n' "''${line#*=}" ;;
          esac
        done <<<"$2"
      }

      ended() {
        case "$(systemctl show "$1" -p ActiveState --value)" in
          inactive | failed) return 0 ;;
          *) return 1 ;;
        esac
      }

      # Asks for a unit through its request file and waits for that run to
      # end, within a deadline in seconds, then exits with what it found.
      #
      # State and invocation ID are read in one call. Each start gets a new
      # ID, which is how this tells its own run from the last one; read
      # apart, a start between the two reads would be mistaken for either.
      run() {
        local verb=$1 unit=$2 deadline=$3 shown state before inv result code
        shown=$(systemctl show "$unit" -p ActiveState -p InvocationID)
        state=$(field ActiveState "$shown")
        before=$(field InvocationID "$shown")
        case "$state" in
          inactive | failed) ;;
          *)
            # A run already going fetched main when it began, perhaps before
            # the merge being deployed, so waiting on it would not say
            # whether that merge is in.
            echo "deploy-agent: $unit is already $state; ask again when it ends" >&2
            exit 75
            ;;
        esac

        # The write, closed, is what the path unit watches for.
        : >"$requests/$verb"

        inv=$before
        for _ in $(seq 30); do
          inv=$(systemctl show "$unit" -p InvocationID --value)
          [ "$inv" != "$before" ] && break
          sleep 1
        done
        if [ "$inv" = "$before" ]; then
          echo "deploy-agent: $unit did not start within 30 seconds" >&2
          exit 1
        fi

        # Losing this session, or giving up here, does not stop the run,
        # which belongs to systemd once started.
        SECONDS=0
        until ended "$unit"; do
          if [ "$SECONDS" -ge "$deadline" ]; then
            echo "deploy-agent: $unit still running after $((deadline / 60)) minutes; it carries on, and 'status' shows how it ends" >&2
            exit 1
          fi
          sleep 5
        done

        shown=$(systemctl show "$unit" -p Result -p ExecMainStatus)
        result=$(field Result "$shown")
        code=$(field ExecMainStatus "$shown")
        if [ "$result" != success ]; then
          echo "deploy-agent: $unit ended with result $result" >&2
          journalctl _SYSTEMD_INVOCATION_ID="$inv" -o cat -n 40 --no-pager >&2 || true
          exit 1
        fi
        if [ "$code" = 75 ]; then
          journalctl _SYSTEMD_INVOCATION_ID="$inv" -o cat -n 5 --no-pager >&2 || true
          exit 75
        fi
      }

      case "''${SSH_ORIGINAL_COMMAND:-}" in
        status) status ;;
        upgrade)
          if [ -e "$hold_flag" ]; then
            echo "deploy-agent: upgrades are held; 'release' first" >&2
            exit 69
          fi
          # A substitute-only run takes minutes. An hour means it is stuck.
          run upgrade ${units.upgrade} 3600
          status
          ;;
        reboot)
          # On success the reboot is under way, and this session may end
          # before the line below is sent.
          run reboot ${units.reboot} 120
          echo "rebooting"
          ;;
        hold)
          run hold ${units.hold} 120
          printf 'hold\t%s\n' "$(held)"
          ;;
        release)
          run release ${units.release} 120
          printf 'hold\t%s\n' "$(held)"
          ;;
        *)
          echo "usage: status | upgrade | reboot | hold | release" >&2
          exit 64
          ;;
      esac
    '';
  };
in
{
  # On the system path so the authorized key can name it by a path that stays
  # put. Its store path would change the key text with every edit to the
  # script, which preflight's brief reads as a change of who can log in.
  # Anyone may run it; it can do nothing without the deploy user's rights.
  environment.systemPackages = [ agent ];

  users.users.deploy = {
    isSystemUser = true;
    group = "deploy";
    # sshd runs a forced command through the login shell, so it needs a real
    # one. The forced command is all it ever runs.
    shell = pkgs.bashInteractive;
    # host-status reads the upgrade's journal, and a failed run prints its
    # own lines back.
    extraGroups = [ "systemd-journal" ];
    openssh.authorizedKeys.keys = map (
      key: ''restrict,command="/run/current-system/sw/bin/deploy-agent" ${key}''
    ) deployPubKeys;
  };
  users.groups.deploy = { };

  # Added to the host's own user in modules/ssh.nix; the lists merge.
  services.openssh.settings.AllowUsers = [ "deploy" ];

  systemd.tmpfiles.rules = [
    "d ${requests} 0700 deploy deploy -"
    "d ${dirOf holdFlag} 0755 root root -"
  ];

  systemd.paths = lib.mapAttrs' (
    verb: unit:
    lib.nameValuePair "deploy-agent-${verb}" {
      description = "Start ${unit} when the deploy login asks";
      wantedBy = [ "paths.target" ];
      pathConfig = {
        PathChanged = "${requests}/${verb}";
        Unit = unit;
      };
    }
  ) units;

  systemd.services = {
    # A held upgrade is skipped, not failed: it did not run, and nothing went
    # wrong. Only where the upgrade exists, or this would define a unit with
    # nothing to run.
    nixos-upgrade = lib.mkIf config.system.autoUpgrade.enable {
      unitConfig.ConditionPathExists = "!${holdFlag}";
    };

    deploy-agent-reboot = {
      description = "Reboot for the deploy login, unless that would cut something off";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = rebootUnlessBusy;
        SuccessExitStatus = 75;
      };
    };
    deploy-agent-hold = {
      description = "Hold the nightly upgrade until released";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.coreutils}/bin/touch ${holdFlag}";
      };
    };
    deploy-agent-release = {
      description = "Release a held nightly upgrade";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.coreutils}/bin/rm -f ${holdFlag}";
      };
    };
  };
}
