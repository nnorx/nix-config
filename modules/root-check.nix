# `root-check`: fails, and so alerts through fleetAlerts, when / is not
# mounted from the device this host's config declares.
#
# core5 fell back to its SD card on 2026-09-04 and looked healthy from every
# angle (docs/recovery.md, "The silent wrong boot"). The fallback boots an old
# generation, which may predate this check, but every host here upgrades
# itself, and so does that generation: within a night the fallback root is
# running main, and this check with it, against the NVMe it is not on.
#
# Only on hosts that upgrade themselves. They are the ones that run unwatched,
# and the ones with the ntfy secret that alerts.nix needs: gate has none, and
# evaluation fails for a declared secret its file lacks.
#
# Once at boot and once a day at noon, outside the reboot window in
# modules/baseline.nix. A host moved to new storage must update its
# `fileSystems."/"`, or this fails daily until it does.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  root-check = pkgs.writeShellApplication {
    name = "root-check";
    runtimeInputs = with pkgs; [
      coreutils
      util-linux
    ];
    text = builtins.readFile ./root-check.sh;
  };
in
{
  config = lib.mkIf config.system.autoUpgrade.enable {
    systemd.services.root-check = {
      description = "Check that / is the declared root device";
      serviceConfig = import ../lib/hardening.nix // {
        Type = "oneshot";
        ExecStart = "${lib.getExe root-check} ${lib.escapeShellArg config.fileSystems."/".device}";
        DynamicUser = true;
      };
    };

    systemd.timers.root-check = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10min";
        OnCalendar = "12:00";
      };
    };

    fleetAlerts.failure = [ "root-check" ];
  };
}
