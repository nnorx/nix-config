# The systemd sandboxing these fleet services start from, kept in one place so
# they cannot drift apart:
#
#   modules/alerts.nix       the notify and heartbeat oneshots
#   modules/offbox-push.nix  each backup push
#   modules/pimon.nix        the monitoring agent and collector
#
# Each merges this into its serviceConfig with `//` and keeps its own settings,
# and its reasons for them, beside it. Plain data rather than a module, so a
# unit that cannot take one of these overrides it in its own attrset.
#
# ProtectSystem=strict makes the whole filesystem read-only to the unit, so a
# service that writes anywhere needs a StateDirectory, RuntimeDirectory or
# ReadWritePaths of its own.
{
  NoNewPrivileges = true;
  ProtectSystem = "strict";
  ProtectHome = true;
  PrivateTmp = true;
  ProtectKernelTunables = true;
  ProtectControlGroups = true;
  RestrictNamespaces = true;
  RestrictSUIDSGID = true;
}
