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
#                          <host>-<unit> and created by their first ping, so
#                          a unit is watched for silence only from its first
#                          success after it is covered. Each needs its grace
#                          raised by hand to 6 hours (README "Alerts").
#
# A host that names a unit here without the matching secret fails evaluation,
# as it does for any declared secret its file lacks (modules/sops-assertions.nix).
#
# A failed upgrade notifies at default priority rather than high. It can fail
# by design, when it starts before cache.yml has finished, and it retries the
# next night; a night with no successful upgrade still alerts from
# healthchecks.io.
{
  config,
  lib,
  pkgs,
  hostname,
  net,
  ...
}:
let
  cfg = config.fleetAlerts;
  upgrade = lib.optional config.system.autoUpgrade.enable "nixos-upgrade";
  failure = lib.unique (cfg.failure ++ upgrade);
  heartbeat = lib.unique (cfg.heartbeat ++ upgrade);

  # A misspelt name, or one with `.service`, would otherwise define an empty
  # stub unit that carries the hook while the real unit goes uncovered.
  realService =
    unit: !(lib.hasSuffix ".service" unit) && config.systemd.services.${unit}.serviceConfig ? ExecStart;

  # Units whose failure notifies at default priority rather than high.
  quiet = upgrade;

  # curl reads its URL from a config on stdin rather than its arguments, so
  # the secret part never appears in the process list. Both secrets arrive as
  # systemd credentials, so the services run as a dynamic user that can read
  # nothing else.
  #
  # core4 and lifeline resolve through their own AdGuard, so an upgrade that
  # leaves it down would also swallow the alert saying so. When curl cannot
  # resolve the name (exit 6), the request is tried again over DNS-over-HTTPS
  # to the public resolvers, addressed by IP, which needs no lookup of its own.
  # Both operators in lib/net.nix serve it at /dns-query.
  dohUrls = map (ip: "https://${ip}/dns-query") net.publicResolvers;
  post =
    name: text:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [ pkgs.curl ];
      text = ''
        unit=''${1%.service}
        send() {
          printf 'url = "%s"\n' "$1" |
            curl -fsS --max-time 30 --retry 5 --retry-all-errors -o /dev/null -K - "''${@:2}"
        }
        post() {
          local status=0
          send "$@" || status=$?
          if [ "$status" -eq 6 ]; then
            for doh in ${lib.escapeShellArgs dohUrls}; do
              send "$@" --doh-url "$doh" && return 0
            done
          fi
          return "$status"
        }
      ''
      + text;
    };

  notify = post "alert-notify" ''
    priority=high
    quiet=" ${toString quiet} "
    case $quiet in
      *" $unit "*) priority=default ;;
    esac
    post "$(<"$CREDENTIALS_DIRECTORY/ntfy-url")" \
      -H "Title: ${hostname}: $unit failed" -H "Priority: $priority" -H "Tags: warning" \
      -d "$unit failed on ${hostname}. journalctl -u $unit there has the details."
  '';

  ping = post "alert-heartbeat" ''
    post "https://hc-ping.com/$(<"$CREDENTIALS_DIRECTORY/healthchecks-ping-key")/${hostname}-$unit?create=1"
  '';

  service = description: script: credential: {
    inherit description;
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = import ../lib/hardening.nix // {
      Type = "oneshot";
      ExecStart = "${lib.getExe script} %i";
      LoadCredential = "${credential}:${config.sops.secrets.${credential}.path}";
      DynamicUser = true;
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
      assertions = map (unit: {
        assertion = realService unit;
        message = ''
          fleetAlerts on ${hostname} names "${unit}", which is not a service
          with an ExecStart. Use the service's name without `.service`.
        '';
      }) (lib.unique (failure ++ heartbeat));
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
