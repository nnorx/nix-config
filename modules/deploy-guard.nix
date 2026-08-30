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
# start services — that is what the recovery USB in the README is for.
{ pkgs, lib, ... }:
let
  stateDir = "/var/lib/deploy-guard";
  armedFile = "${stateDir}/armed";

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

      case "''${1:-}" in
        arm)
          require_root arm
          minutes=''${2:-15}
          gen=$(running_generation)
          mkdir -p "$state"
          printf '%s %s\n' "$minutes" "$gen" > "$armed"
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
            echo "armed for next boot: $(cat "$armed") (minutes generation)"
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
          read -r minutes gen < "$armed"

          # Consume the marker up front. Arming applies to exactly one boot, so
          # a later unrelated reboot must not inherit a countdown, and neither
          # must the reboot this guard is about to trigger.
          rm -f "$armed"

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
