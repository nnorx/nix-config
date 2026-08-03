# Raspberry Pi 5 — future homelab
# Boot handled by nixos-raspberrypi (kernel bootloader + Pi firmware, not U-Boot)
{
  hostname,
  lib,
  net,
  ...
}:
let
  host = net.hosts.${hostname};
in
{
  imports = [
    ../../modules/docker.nix
    (import ../../modules/pimon.nix {
      mode = "collector";
      bind = "0.0.0.0";
      port = net.ports.pimon;
    })
    (import ../../modules/pimon.nix {
      mode = "agent";
      collectorUrl = "http://127.0.0.1:${toString net.ports.pimon}";
    })
  ];

  networking.hostName = hostname;

  # Docker access for this host's user
  users.users.${hostname}.extraGroups = [ "docker" ];

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
  networking.interfaces.${host.iface}.ipv4.addresses = [
    {
      address = host.ip;
      inherit (net.lan) prefixLength;
    }
  ];
  networking.defaultGateway = net.lan.gateway;
  networking.nameservers = [
    "1.1.1.1"
    "8.8.8.8"
  ];

  # pimon collector — allow the collector port only from other Pis
  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -p tcp --dport ${toString net.ports.pimon} -s ${net.hosts.core3.ip} -j nixos-fw-accept
    iptables -A nixos-fw -p tcp --dport ${toString net.ports.pimon} -s ${net.hosts.core4.ip} -j nixos-fw-accept
  '';
}
