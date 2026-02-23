# System hardening and maintenance baseline for all Pis
{ lib, ... }:
{
  # Automatic NixOS upgrades from the flake
  system.autoUpgrade = {
    enable = true;
    flake = "github:nnorx/nix-config";
    dates = "04:00";
    allowReboot = true;
    rebootWindow = {
      lower = "03:00";
      upper = "05:00";
    };
  };

  # Nix garbage collection — keep SD cards from filling up
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  # Enable flakes and the nix command
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Kernel / sysctl hardening
  boot.kernel.sysctl = {
    "net.ipv4.conf.all.rp_filter" = 1;
    "net.ipv4.conf.default.rp_filter" = 1;
    "net.ipv4.icmp_ignore_bogus_error_responses" = 1;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.default.send_redirects" = 0;
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv6.conf.all.accept_redirects" = 0;
    "kernel.sysrq" = 0;
  };

  # Sudo — only wheel group, require password
  security.sudo = {
    execWheelOnly = true;
    wheelNeedsPassword = true;
  };

  # Lightweight NTP for accurate time
  services.timesyncd.enable = true;

  # Disable services not needed on headless Pis
  services.avahi.enable = false;

  # Journald — cap disk usage on SD cards
  services.journald.extraConfig = ''
    SystemMaxUse=200M
    MaxRetentionSec=1month
  '';
}
