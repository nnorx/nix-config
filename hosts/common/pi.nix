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

  # SD card filesystem layout (standard NixOS Pi image partitioning)
  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
  };
}
