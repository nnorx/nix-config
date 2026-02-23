# Shared NixOS configuration for all Raspberry Pis
{
  pkgs,
  lib,
  hostname,
  ...
}:
{
  imports = [
    ../../modules/baseline.nix
    ../../modules/ssh.nix
    ../../modules/firewall.nix
    ../../modules/fail2ban.nix
    ../../modules/docker.nix
  ];

  system.stateVersion = "25.11";

  # Boot — Pi 3/4 use U-Boot/extlinux; Pi 5 overrides this via nixos-raspberrypi
  boot.loader.grub.enable = lib.mkDefault false;
  boot.loader.generic-extlinux-compatible.enable = lib.mkDefault true;

  # SD card filesystem layout (standard NixOS Pi image partitioning)
  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
  };

  # Locale and timezone
  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  # Networking
  networking.useDHCP = false;

  # User account — hostname doubles as username (core3, core4, core5)
  users.users.${hostname} = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "docker"
    ];
    shell = pkgs.zsh;
  };

  # Zsh must be enabled system-wide for it to work as a login shell
  programs.zsh.enable = true;

  # Minimal set of system packages
  environment.systemPackages = with pkgs; [
    git
    vim
    curl
    htop
  ];
}
