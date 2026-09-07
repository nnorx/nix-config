# Raspberry Pi boot and storage layout.
#
# Split out of hosts/common so non-Pi hosts can share the rest. `fileSystems."/"`
# in particular is an unprioritized assignment, which would collide with the
# `fileSystems."/"` in any x86 host's generated hardware-configuration.nix.
{ lib, hostname, ... }:
let
  # Staggered, and not for tidiness. `system.autoUpgrade.randomizedDelaySec`
  # defaults to "0", so without distinct times all three Pis fire at the same
  # instant, and on any kernel bump core4 and lifeline reboot together. Those
  # are the fleet's two deliberately independent resolvers, and taking them
  # down simultaneously removes the one property the whole DNS design exists to
  # provide.
  #
  # lifeline first: it is the resolver the house depends on least at any given
  # moment. core4 an hour later, then core5, which serves no DNS at all. An
  # hour is far longer than a Pi needs to come back, so the second upgrade
  # starts from a house that is already resolving again.
  #
  # What this does not buy: safety from a bad generation. Nobody is awake at
  # 04:00 to notice the first host failed before the second takes the same
  # config. It converts a simultaneous outage into a sequential one, which is
  # worth having and is not the same as a canary.
  upgradeTimes = {
    lifeline = "03:00";
    core4 = "04:00";
    core5 = "05:00";
  };
in
{
  # Automatic upgrades are enabled here rather than in modules/baseline.nix
  # because this file is imported by exactly the three Pis and not by gate.
  # See the comment on `system.autoUpgrade` there for why gate stays manual.
  system.autoUpgrade = {
    enable = true;
    dates = upgradeTimes.${hostname} or "05:30";
  };

  # Pi 3/4 use U-Boot/extlinux; the Pi 5 overrides this via nixos-raspberrypi
  boot.loader.grub.enable = lib.mkDefault false;
  boot.loader.generic-extlinux-compatible.enable = lib.mkDefault true;

  # SD card filesystem layout (standard NixOS Pi image partitioning).
  #
  # mkDefault so a Pi that has been moved off its SD card can declare its own
  # root. Unprioritised, this is the same shape of problem gate hit with
  # stateVersion: the only way past it is mkForce in the host, which reads as
  # fighting the module rather than overriding a default.
  #
  # Note the label is not unique to a card: every NixOS Pi image ships
  # NIXOS_SD, and the same fixed root UUID. Anything that has to coexist with
  # an SD card should be addressed by its own UUID.
  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
  };
}
