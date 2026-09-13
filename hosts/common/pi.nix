# Raspberry Pi boot and storage layout, and the Pis' automatic upgrades.
#
# Split out of hosts/common so non-Pi hosts can share the rest. `fileSystems."/"`
# in particular is an unprioritized assignment, which would collide with the
# `fileSystems."/"` in any x86 host's generated hardware-configuration.nix.
#
# Upgrades are switched on here because this file is imported by the Pis and
# by nothing else. modules/baseline.nix holds the shared settings, and why gate
# must not have them.
{ lib, hostname, ... }:
let
  # An hour apart, because `randomizedDelaySec` defaults to "0": on one shared
  # time every Pi upgrades at once, and a kernel bump reboots both resolvers
  # together, which is a house-wide DNS outage.
  #
  # The gap is between starts, not reboots. A host reboots a minute after its
  # own run finishes, so a run over an hour could still land beside the next
  # one; a substitute-only run takes minutes. Which resolver goes first is
  # arbitrary, since Kea hands clients both. core5 serves no DNS and goes last.
  #
  # This is not a canary. Nobody is awake to notice the first host failing
  # before the next takes the same config. It turns one simultaneous outage
  # into sequential ones, which is worth having and is not safety.
  upgradeTimes = {
    lifeline = "03:00";
    core4 = "04:00";
    core5 = "05:00";
  };
in
{
  # mkDefault, like everything else in this file, so a Pi can stay manual
  # during a migration with a plain `enable = false` rather than mkForce.
  #
  # A Pi missing from the table is an evaluation error, not a default slot. A
  # default is how a renamed or newly added resolver ends up sharing one.
  system.autoUpgrade = {
    enable = lib.mkDefault true;
    dates = lib.mkDefault (
      upgradeTimes.${hostname} or (throw ''
        hosts/common/pi.nix has no upgrade time for "${hostname}". Add it to
        upgradeTimes, keeping it an hour from any other resolver.
      '')
    );
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
