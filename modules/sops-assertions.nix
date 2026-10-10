# Every secret a host declares must be in its sops file, or evaluation fails.
#
# sops-nix would catch a missing key too, but only when the system is built,
# and CI only evaluates: the change would merge, cache.yml would fail to build
# the Pis, and their upgrades would stop with nothing yet installed to say so.
# So the check reads the file's key names, which sops leaves in plaintext.
#
# It covers secrets that use the host's default file, which today is all of
# them, and looks for each one's `key` (its name unless set) at the top level.
# A secret with its own `sopsFile` is not checked.
{ config, lib, ... }:
let
  file = config.sops.defaultSopsFile;
  text = builtins.readFile file;
  # A top-level key, at the start of a line, and not a longer key ending in it.
  has = key: lib.hasPrefix "${key}:" text || lib.hasInfix "\n${key}:" text;
in
{
  assertions = lib.concatLists (
    lib.mapAttrsToList (
      name: secret:
      lib.optional (secret.sopsFile == file) {
        assertion = has secret.key;
        message = ''
          ${config.networking.hostName} declares sops.secrets.${name}, but
          secrets/${baseNameOf (toString file)} has no `${secret.key}`. The README's
          "Alerts" and docs/night-shift.md show the `sops set` command that adds one.
        '';
      }
    ) config.sops.secrets
  );
}
