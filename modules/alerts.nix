# Tells someone when a job that matters fails, or stops running at all.
#
#   fleetAlerts.failure    Units whose failure sends a push notification
#                          through ntfy.sh, to a topic only the phone knows.
#   fleetAlerts.heartbeat  Units that ping healthchecks.io each time they
#                          succeed. A check that stays quiet past its period
#                          alerts from there, which covers what no failure
#                          hook can: a timer that never fires, a host that is
#                          off, or core5 itself being the thing that is down.
#
# The automatic upgrade adds itself to both wherever it is enabled, and every
# offbox-push job adds itself (modules/offbox-push.nix). Until this existed,
# all three failed only into the journal (docs/router.md, Phase 8).
#
# Both services are hosted, deliberately: an alert that depends on the house
# being up cannot report the house being down. What leaves the host is the
# host's name, the unit's name and the word "failed". No log lines, which can
# carry addresses this repo keeps private.
#
# Secrets, per host, in secrets/<host>.yaml:
#
#   ntfy-url               https://ntfy.sh/<topic>. The topic name is the
#                          only access control ntfy.sh has, so it is random
#                          and secret.
#   healthchecks-ping-key  The project's ping key. Checks are named
#                          <host>-<unit> and created by their first ping.
#
# A host that names a unit here without the matching secret fails evaluation.
# The check reads the sops file's key names, which sops leaves in plaintext.
# Without it the host would activate, sops-nix would fail on the missing key,
# and every secret on the host, the deploy key included, would go with it.
{
  config,
  lib,
  pkgs,
  hostname,
  ...
}:
let
  cfg = config.fleetAlerts;
  upgrade = lib.optional config.system.autoUpgrade.enable "nixos-upgrade";
  failure = lib.unique (cfg.failure ++ upgrade);
  heartbeat = lib.unique (cfg.heartbeat ++ upgrade);

  sopsFile = config.sops.defaultSopsFile;
  hasSecret = key: builtins.match "(.*\n)?${key}:.*" (builtins.readFile sopsFile) != null;
  needs = key: units: {
    assertion = units == [ ] || hasSecret key;
    message = ''
      fleetAlerts on ${hostname} covers ${toString units}, but secrets/${baseNameOf (toString sopsFile)}
      has no `${key}`. See modules/alerts.nix, and add it before this reaches
      the host: a missing key fails every secret on it at activation.
    '';
  };

  # curl reads its URL from a config on stdin rather than its arguments, so
  # the secret part never appears in the process list. Both secrets arrive as
  # systemd credentials, so the services run as a dynamic user that can read
  # nothing else.
  post =
    name: text:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [ pkgs.curl ];
      text = ''
        unit=''${1%.service}
        post() {
          printf 'url = "%s"\n' "$1" |
            curl -fsS --max-time 30 --retry 5 --retry-all-errors -o /dev/null -K - "''${@:2}"
        }
      ''
      + text;
    };

  notify = post "alert-notify" ''
    post "$(<"$CREDENTIALS_DIRECTORY/ntfy-url")" \
      -H "Title: ${hostname}: $unit failed" -H "Priority: high" -H "Tags: warning" \
      -d "$unit failed on ${hostname}. journalctl -u $unit there has the details."
  '';

  ping = post "alert-heartbeat" ''
    post "https://hc-ping.com/$(<"$CREDENTIALS_DIRECTORY/healthchecks-ping-key")/${hostname}-$unit?create=1"
  '';

  service = description: script: credential: {
    inherit description;
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe script} %i";
      LoadCredential = "${credential}:${config.sops.secrets.${credential}.path}";
      DynamicUser = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictNamespaces = true;
      RestrictSUIDSGID = true;
    };
  };
in
{
  options.fleetAlerts = {
    failure = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Service names, without .service, whose failure sends a notification.";
    };
    heartbeat = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Service names, without .service, that ping healthchecks.io on success.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        (needs "ntfy-url" failure)
        (needs "healthchecks-ping-key" heartbeat)
      ];
    }

    (lib.mkIf (failure != [ ]) {
      sops.secrets.ntfy-url = { };
      systemd.services."alert-notify@" = service "Notify that %i failed" notify "ntfy-url";
    })

    (lib.mkIf (heartbeat != [ ]) {
      sops.secrets.healthchecks-ping-key = { };
      systemd.services."alert-heartbeat@" =
        service "Tell healthchecks.io that %i succeeded" ping
          "healthchecks-ping-key";
    })

    {
      systemd.services = lib.mkMerge (
        map (unit: { ${unit}.onFailure = [ "alert-notify@%n.service" ]; }) failure
        ++ map (unit: { ${unit}.onSuccess = [ "alert-heartbeat@%n.service" ]; }) heartbeat
      );
    }
  ];
}
