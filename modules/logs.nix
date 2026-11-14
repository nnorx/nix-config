# The fleet's journals, on the collector: VictoriaLogs on loopback, which
# Grafana and core5's own upload use, and a vmauth on core5's address in front
# of it that passes journal uploads alone, from the other metricsTargets. Each
# host's side is ./journal-upload.nix. docs/observability.md is the runbook.
{
  config,
  lib,
  pkgs,
  hostname,
  net,
  unstable,
  ...
}:
let
  host = net.hosts.${hostname};
  hardening = import ../lib/hardening.nix;
  storeAddress = "127.0.0.1:${toString net.ports.victoriaLogs}";
  insertPort = net.ports.victoriaLogsInsert;

  # Each uploader at the address it reaches core5 from: gate at the gateway
  # of its metricsSegment, as it is scraped.
  sources = map (
    name: net.hosts.${name}.ip or net.segments.${net.hosts.${name}.metricsSegment}.gateway
  ) (lib.remove hostname net.metricsTargets);

  adminKey = "/run/victorialogs-admin-key";

  # systemd-journal-upload's one path. Anything else, a select, a delete or
  # another ingestion protocol, matches no route and vmauth refuses it.
  vmauthConfig = pkgs.writeText "vmauth-logs.yml" (
    builtins.toJSON {
      unauthorized_user.url_map = [
        {
          src_paths = [ "/insert/journald/upload" ];
          url_prefix = "http://${storeAddress}";
        }
      ];
    }
  );
in
{
  assertions = [
    {
      assertion = hostname == net.metricsCollector;
      message = ''
        ${hostname} imports modules/logs.nix, but net.metricsCollector is
        "${net.metricsCollector}", where every host uploads its journal.
      '';
    }
  ];

  services.victorialogs = {
    enable = true;
    listenAddress = storeAddress;
    extraOptions = [
      # About 90,000 lines a day across the fleet, measured 2026-11-13. The
      # disk cap drops the oldest days first if a year of that outgrows it;
      # the free-space floor is the metrics store's, and stops ingestion
      # rather than fill the disk Home Assistant shares.
      "-retentionPeriod=1y"
      "-retention.maxDiskSpaceUsageBytes=20GiB"
      "-storage.minFreeDiskSpaceBytes=50GiB"
    ]
    # Delete is off, `-delete.enable` unset. The rest of the admin endpoints
    # take this key, as the metrics store's do (./metrics.nix). The module
    # escapes `%`, so the credential's path is written out.
    ++ map (flag: "-${flag}=file:///run/credentials/victorialogs.service/admin-key") [
      "forceMergeAuthKey"
      "forceFlushAuthKey"
      "partitionManageAuthKey"
      "logNewStreamsAuthKey"
      "flagsAuthKey"
      "pprofAuthKey"
    ];
  };

  systemd.services.victorialogs.serviceConfig = hardening // {
    ProtectSystem = lib.mkForce hardening.ProtectSystem;
    LoadCredential = [ "admin-key:${adminKey}" ];
  };

  systemd.services.victorialogs-admin-key = {
    description = "Make the key VictoriaLogs' admin APIs take";
    before = [ "victorialogs.service" ];
    requiredBy = [ "victorialogs.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
    };
    script = ''
      if [ ! -s ${adminKey} ]; then
        key=$(${lib.getExe pkgs.openssl} rand -hex 32)
        printf '%s' "$key" > ${adminKey}
      fi
    '';
  };

  systemd.services.vmauth-logs = {
    description = "Pass journal uploads alone to VictoriaLogs";
    wantedBy = [ "multi-user.target" ];
    after = [ "victorialogs.service" ];
    serviceConfig = hardening // {
      ExecStart = lib.escapeShellArgs [
        (lib.getExe' config.services.victoriametrics.package "vmauth")
        "-auth.config=${vmauthConfig}"
        "-httpListenAddr=${host.ip}:${toString insertPort}"
        "-httpInternalListenAddr=unix:/run/vmauth-logs/internal.sock"
      ];
      DynamicUser = true;
      RuntimeDirectory = "vmauth-logs";
      RuntimeDirectoryMode = "0700";
      Restart = "on-failure";
      RestartSec = "5s";
      # The firewall's sources again, and loopback for the store.
      IPAddressDeny = "any";
      IPAddressAllow = sources ++ [ "localhost" ];
      # The one unit here listening beyond loopback, so narrower than the
      # baseline: the rest of what VictoriaLogs' own module sets.
      CapabilityBoundingSet = "";
      PrivateDevices = true;
      PrivateUsers = true;
      ProtectClock = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      RestrictRealtime = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [
        "@system-service"
        "~@privileged"
        "~@resources"
      ];
    };
  };

  networking.firewall.extraCommands = lib.concatMapStrings (source: ''
    iptables -A nixos-fw -i ${host.iface} -p tcp --dport ${toString insertPort} -s ${source} -j nixos-fw-accept
  '') sources;

  # From `unstable` with Grafana itself (./metrics.nix).
  services.grafana = {
    declarativePlugins = [ unstable.grafanaPlugins.victoriametrics-logs-datasource ];
    provision.datasources.settings.datasources = [
      {
        name = "VictoriaLogs";
        uid = "victorialogs";
        type = "victoriametrics-logs-datasource";
        url = "http://${storeAddress}";
      }
    ];
  };
}
