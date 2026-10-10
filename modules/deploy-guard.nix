# Automatic rollback for deploys that only fail after a reboot.
#
# `nixos-rebuild test` is the normal way to try a risky change without
# committing to it: it activates without touching the bootloader, so a reboot
# undoes it. That does not cover boot-time changes. Interface renames land in
# udev at device enumeration, and initrd or bootloader changes never take
# effect at all, so those need `boot` plus a reboot, which is precisely the
# form that can leave an unreachable box.
#
# This closes that gap. Arm before rebooting; if the new generation comes up
# and nobody confirms within the window, the box returns itself to the
# generation that was running when it was armed.
#
# It covers "boots, but is unreachable", which is the likely failure for
# networking changes. It cannot help if the system does not boot far enough to
# start services — that is what the recovery USB in docs/recovery.md is for.
{ pkgs, lib, ... }:
let
  stateDir = "/var/lib/deploy-guard";
  armedFile = "${stateDir}/armed";

  # How long an arm stays good. The runbook arms, rebuilds and reboots in one
  # sitting, so a marker older than this was abandoned, not waiting.
  maxAgeHours = 6;

  deploy-guard = pkgs.writeShellApplication {
    name = "deploy-guard";
    runtimeInputs = with pkgs; [
      systemd
      nix
      coreutils
    ];
    text = ''
      state=${stateDir}
      armed=${armedFile}
      profile=/nix/var/nix/profiles/system
      max_age=$((${toString maxAgeHours} * 3600))

      # The generation currently *running*, which is not the same as the one
      # the profile points at: `nixos-rebuild boot` advances the profile while
      # leaving the running system alone. Arming has to record the former, so
      # it works whether it is run before or after the rebuild.
      running_generation() {
        target=$(readlink -f /run/current-system)
        for link in "$profile"-*-link; do
          if [ "$(readlink -f "$link")" = "$target" ]; then
            link=''${link##*/system-}
            echo "''${link%-link}"
            return 0
          fi
        done
        echo "cannot identify the running generation" >&2
        return 1
      }

      # arm, confirm and disarm all write under /var/lib or drive systemd, so
      # they need root. Failing loudly matters most for confirm: a confirm that
      # reports success without stopping the countdown is worse than no
      # confirm at all, because it is believed.
      require_root() {
        if [ "$(id -u)" -ne 0 ]; then
          echo "deploy-guard $1 must run as root (try sudo)" >&2
          exit 1
        fi
      }

      # The arm time from a marker's third field, in seconds since the epoch.
      # Prints nothing when the field is missing or is not a number, which the
      # callers treat as an arm that does not expire.
      armed_time() {
        case "''${1:-}" in
          "" | *[!0-9]*) ;;
          *) echo "$1" ;;
        esac
      }

      case "''${1:-}" in
        arm)
          require_root arm
          minutes=''${2:-15}
          gen=$(running_generation)
          mkdir -p "$state"
          printf '%s %s %s\n' "$minutes" "$gen" "$(date +%s)" > "$armed"
          echo "Armed. If generation $gen is not confirmed within $minutes"
          echo "minutes of the next boot, the box rolls back to it and reboots."
          echo "After rebooting, run: deploy-guard confirm"
          ;;
        confirm | disarm)
          require_root "$1"
          if systemctl is-active --quiet deploy-guard.service; then
            systemctl stop deploy-guard.service
          fi
          rm -f "$armed"
          if systemctl is-active --quiet deploy-guard.service; then
            echo "countdown is still running; NOT confirmed" >&2
            exit 1
          fi
          echo "Confirmed. No rollback pending."
          ;;
        status)
          if [ -e "$armed" ]; then
            read -r minutes gen armed_at < "$armed"
            echo "armed for next boot: generation $gen, $minutes minutes"
            armed_at=$(armed_time "''${armed_at:-}")
            if [ -z "$armed_at" ]; then
              echo "arm time not recorded, so it does not expire"
            elif [ "$(($(date +%s) - armed_at))" -gt "$max_age" ]; then
              echo "armed $(date -d "@$armed_at"): expired, the next boot ignores it"
              echo "'deploy-guard disarm' clears it"
            else
              echo "armed $(date -d "@$armed_at"), expires after ${toString maxAgeHours} hours"
            fi
          else
            echo "not armed"
          fi
          if systemctl is-active --quiet deploy-guard.service; then
            echo "countdown running now; 'deploy-guard confirm' cancels it"
          fi
          echo "running generation: $(running_generation)"
          ;;
        run)
          # Called by the unit at boot, not by hand.
          [ -e "$armed" ] || exit 0
          read -r minutes gen armed_at < "$armed"

          # Consume the marker up front. Arming applies to exactly one boot, so
          # a later unrelated reboot must not inherit a countdown, and neither
          # must the reboot this guard is about to trigger.
          rm -f "$armed"

          # An arm whose reboot never came is abandoned: `nrb && reboot` skips
          # the reboot when the build fails, and a fix deployed with `nrs`
          # never consumes the marker. Left alone, it would roll back on
          # whatever reboot came next, perhaps weeks later, to a generation
          # that may no longer match the rest of the network. So an old arm is
          # ignored.
          #
          # Anything else keeps the protection. A marker with no time was
          # written before arms recorded one, which includes the arm for the
          # deploy that installs this check. A negative age means the clock is
          # wrong at boot, so the age cannot be trusted either way.
          armed_at=$(armed_time "''${armed_at:-}")
          if [ -n "$armed_at" ] && [ "$(($(date +%s) - armed_at))" -gt "$max_age" ]; then
            echo "deploy-guard: ignoring an arm from $(date -d "@$armed_at"), over ${toString maxAgeHours} hours old; no rollback"
            exit 0
          fi

          echo "deploy-guard: rolling back to generation $gen in $minutes minutes unless confirmed"
          sleep "$((minutes * 60))"

          echo "deploy-guard: not confirmed, rolling back to generation $gen"
          nix-env --profile "$profile" --switch-generation "$gen"
          "$profile"/bin/switch-to-configuration boot
          systemctl reboot
          ;;
        *)
          echo "usage: sudo deploy-guard arm [minutes] | confirm | disarm; deploy-guard status" >&2
          exit 64
          ;;
      esac
    '';
  };
in
{
  environment.systemPackages = [ deploy-guard ];

  systemd.services.deploy-guard = {
    description = "Roll back to the previous generation unless a deploy is confirmed";
    wantedBy = [ "multi-user.target" ];

    # The countdown must outlive the unit's start-up, so this is a long-running
    # service rather than a oneshot: `deploy-guard confirm` cancels it by
    # stopping the unit, which kills the sleep.
    serviceConfig = {
      Type = "simple";
      ExecStart = "${lib.getExe deploy-guard} run";

      # A rollback that itself fails must not be retried into a reboot loop.
      Restart = "no";
    };
  };
}
