# What scripts/preflight.sh evaluates, once for the working tree and once for
# the base it compares against. `ref` is a flake reference.
#
# Every commit changes every host's toplevel through system.configurationRevision,
# so each is evaluated with the revision pinned: two sides then differ only when
# the change itself reaches that host. Home Manager configs carry no revision
# and are compared as they are.
{ ref }:
let
  flake = builtins.getFlake ref;

  pinned =
    c:
    (c.extendModules {
      modules = [ { system.configurationRevision = c.pkgs.lib.mkForce "pinned"; } ];
    }).config.system.build.toplevel.drvPath;
in
{
  hosts = builtins.mapAttrs (_: c: {
    drv = pinned c;
    # A host that upgrades itself takes whatever reaches main, unattended.
    autoUpgrade = c.config.system.autoUpgrade.enable;
  }) flake.nixosConfigurations;

  homes = builtins.mapAttrs (_: h: h.activationPackage.drvPath) flake.homeConfigurations;
}
