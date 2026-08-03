# pimon — lightweight fleet monitoring agent
# Parameterized: each host specifies its role (agent or collector)
{
  mode, # "agent" or "collector"
  collectorUrl ? null, # Required for agent mode; unused by the collector
  interval ? 10,
  port ? 8080,
  bind ? "0.0.0.0",
  staleSecs ? 120,
  maxHosts ? 16,
}:
{ pimonPkg, ... }:
{
  environment.systemPackages = [ pimonPkg ];

  systemd.services."pimon-${mode}" = {
    description = "pimon ${mode}";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = 10;
      DynamicUser = true;

      # Hardening
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictNamespaces = true;
      RestrictSUIDSGID = true;

      ExecStart =
        if mode == "agent" then
          assert collectorUrl != null;
          "${pimonPkg}/bin/pimon agent --collector-url ${collectorUrl} --interval ${toString interval}"
        else
          "${pimonPkg}/bin/pimon collect --port ${toString port} --bind ${bind} --stale-secs ${toString staleSecs} --max-hosts ${toString maxHosts}";
    };
  };
}
