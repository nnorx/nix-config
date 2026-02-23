# Raspberry Pi 5 — future homelab
# Boot handled by nixos-raspberrypi (kernel bootloader + Pi firmware, not U-Boot)
{ hostname, lib, ... }:
{
  networking.hostName = hostname;

  # Pi 5 boot — override the extlinux default from hosts/common
  boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;
  boot.loader.raspberry-pi.bootloader = "kernel";

  # Pi 5 firmware partition (managed by nixos-raspberrypi bootloader module)
  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    options = [
      "noatime"
      "noauto"
      "x-systemd.automount"
      "x-systemd.idle-timeout=1min"
    ];
  };

  # Static IP
  networking.interfaces.end0.ipv4.addresses = [
    {
      address = "192.168.86.49";
      prefixLength = 24;
    }
  ];
  networking.defaultGateway = "192.168.86.1";
  networking.nameservers = [
    "1.1.1.1"
    "8.8.8.8"
  ];

  # Homelab services will be added here
}
