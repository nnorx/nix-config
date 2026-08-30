# System hardening and maintenance baseline for every host
{ lib, ... }:
{
  # Automatic NixOS upgrades from the flake.
  #
  # Paused: unattended 3-5am reboots are hard to tell apart from a fault while
  # hosts are being physically moved, so deploys are manual for now. Re-enable
  # by flipping this back to true.
  system.autoUpgrade = {
    enable = false;
    flake = "github:nnorx/nix-config";
    # Without this the flake's nixConfig is ignored, so an unattended upgrade
    # would skip the binary caches and compile the kernel on the host.
    flags = [ "--accept-flake-config" ];
    dates = "04:00";
    allowReboot = true;
    rebootWindow = {
      lower = "03:00";
      upper = "05:00";
    };
  };

  # Nix garbage collection — keeps SD cards from filling up, and bounds how
  # many generations gate's ESP has to hold
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  # Binary caches, baked into each host's nix.conf so they apply to every user
  # and every nix invocation. The same list lives in flake.nix's nixConfig, but
  # that form is client-supplied: Nix ignores it for anyone outside
  # trusted-users, and only honours it with --accept-flake-config. Relying on
  # the flake copy alone means a host silently compiles instead of substituting
  # — which for linux_rpi4 is 9-15 hours on a Pi 4.
  nix.settings = {
    substituters = [
      "https://nixos-raspberrypi.cachix.org"
      "https://nnorx-nix-config.cachix.org"
    ];
    trusted-public-keys = [
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
      "nnorx-nix-config.cachix.org-1:/vn4K3PMf39c802pIvdiQ8ErecC5eTFuXxQ6/g6Sqro="
    ];
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

  # Disable services not needed on a headless box
  services.avahi.enable = false;

  # Journald — cap disk usage on SD cards. gate raises this in its own host
  # config: it has NVMe, and it is the host whose logs are worth keeping
  services.journald.extraConfig = ''
    SystemMaxUse=200M
    MaxRetentionSec=1month
  '';
}
