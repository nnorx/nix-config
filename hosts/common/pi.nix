# Raspberry Pi boot and storage layout.
#
# Split out of hosts/common so non-Pi hosts can share the rest. `fileSystems."/"`
# in particular is an unprioritized assignment, which would collide with the
# `fileSystems."/"` in any x86 host's generated hardware-configuration.nix.
{ lib, ... }:
{
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
