# What scripts/preflight.sh evaluates, once for the change and once for the
# base it compares against. `ref` is a flake reference.
#
# Every commit changes every host's toplevel through system.configurationRevision,
# so each is evaluated with the revision pinned: two sides then differ only when
# the change itself reaches that host. Home Manager configs carry no revision
# and are compared as they are.
#
# Beside the toplevel, each host reports the pieces scripts/preflight-brief.jq
# reasons about: what decides a reboot, the boot path, each unit, each file in
# /etc, and who can log in. Comparing pieces says what kind of change reaches a
# host, where the toplevel alone says only that something does. All of them are
# evaluated anyway on the way to the toplevel, so this costs seconds.
{ ref }:
let
  flake = builtins.getFlake ref;

  facts =
    host:
    let
      inherit (host.pkgs) lib;
      c =
        (host.extendModules {
          modules = [ { system.configurationRevision = lib.mkForce "pinned"; } ];
        }).config;
      enabled = lib.filterAttrs (_: x: x.enable);
    in
    {
      drv = c.system.build.toplevel.drvPath;

      # A host that upgrades itself takes whatever reaches main, unattended.
      autoUpgrade = c.system.autoUpgrade.enable;
      allowReboot = c.system.autoUpgrade.allowReboot;
      upgradeAt = c.system.autoUpgrade.dates;
      rebootWindow = c.system.autoUpgrade.rebootWindow;
      # Where risky deploys go behind modules/deploy-guard.nix (gate).
      deployGuard = c.systemd.services ? deploy-guard;

      # The three paths nixpkgs' auto-upgrade compares with the booted system
      # to choose between rebooting and switching (nixos/modules/tasks/
      # auto-upgrade.nix). Any of them changing means a reboot.
      reboot = {
        kernel = c.system.build.kernel.drvPath;
        initrd = c.system.build.initialRamdisk.drvPath;
        modules = c.system.modulesTree.drvPath;
      };
      kernelVersion = c.boot.kernelPackages.kernel.version;

      # What the next boot runs that a switch installs but never exercises. A
      # change here is first tested by whichever reboot comes next, planned or
      # not.
      boot = {
        loader = c.system.build.installBootLoader;
        params = c.boot.kernelParams;
        # A list in older nixpkgs, one merged package in newer.
        firmware = map (p: p.drvPath) (lib.toList c.hardware.firmware);
      };

      units = lib.mapAttrs (_: u: u.unit.drvPath) (enabled c.systemd.units);
      # What switch-to-configuration does with a service whose unit changed.
      services = lib.mapAttrs (_: s: {
        restart = s.restartIfChanged;
        reload = s.reloadIfChanged;
      }) (enabled c.systemd.services);

      # sshd_config, authorized keys, networkd files and the rest of /etc.
      etc = lib.mapAttrs (_: e: "${e.source}") (enabled c.environment.etc);

      # Who can log in, and how. mutableUsers is off, so a user dropped here is
      # deleted on activation. root is always listed, so losing its last key
      # reads as a key change rather than as root being deleted. Key files
      # are compared by content, since their paths move with every commit;
      # the password only by a hash of how it is set, never the value.
      users =
        lib.mapAttrs
          (_: u: {
            inherit (u) uid;
            groups = u.extraGroups;
            keys = u.openssh.authorizedKeys.keys;
            keyFiles = map (
              f: builtins.hashString "sha256" (builtins.readFile f)
            ) u.openssh.authorizedKeys.keyFiles;
            password = builtins.hashString "sha256" (
              builtins.toJSON { inherit (u) hashedPassword hashedPasswordFile password; }
            );
          })
          (
            lib.filterAttrs (
              _: u: u.isNormalUser || u.uid == 0 || u.openssh.authorizedKeys.keys != [ ]
            ) c.users.users
          );

      # Named first when versions move, ahead of the build closure's long tail.
      packages = map (p: p.pname or (builtins.parseDrvName p.name).name) c.environment.systemPackages;
    };
in
{
  hosts = builtins.mapAttrs (_: facts) flake.nixosConfigurations;

  homes = builtins.mapAttrs (_: h: h.activationPackage.drvPath) flake.homeConfigurations;
}
