# System hardening and maintenance baseline for every host
{ lib, ... }:
{
  # Automatic NixOS upgrades from the flake.
  #
  # Off here and switched on in hosts/common/pi.nix, so it reaches the three
  # Pis and not gate. The original pause was for the rack migration, which is
  # long finished; gate stays manual for a different and permanent reason. It
  # is the house's only route to the internet and the Nest is gone, so an
  # unattended reboot onto a bad generation at 4am has no rollback router
  # behind it, only the recovery USB and whoever notices. A Pi is a card pull.
  #
  # mkDefault rather than plain false, so pi.nix can turn it on without this
  # having to know which hosts are Pis.
  system.autoUpgrade = {
    enable = lib.mkDefault false;
    flake = "github:nnorx/nix-config";
    flags = [
      # Without this the flake's nixConfig is ignored, so an unattended upgrade
      # would skip the binary caches.
      "--accept-flake-config"

      # Substitute or fail. Never build on the host.
      #
      # linux_rpi4 is in no public cache, which is the entire reason
      # .github/workflows/cache.yml exists, and a Pi 4 that starts compiling it
      # unattended at 3am is still compiling at lunchtime: fanless, warm, and
      # serving DNS the whole time. The race is real rather than theoretical,
      # because cache.yml can take hours on a kernel bump and both are
      # triggered by the same push to main.
      #
      # `--max-jobs 0` refuses to build anything locally, so an upgrade that
      # outruns the cache workflow fails cleanly and the timer tries again
      # rather than melting a Pi.
      #
      # The cost is that a genuinely uncached path stops upgrades silently, and
      # a host that quietly stopped upgrading looks exactly like one with
      # nothing to do. That is a real gap until the wrong-boot detection in
      # docs/router.md exists, and it is the safer side of the trade.
      "--max-jobs"
      "0"
    ];
    allowReboot = true;

    # Wide enough to contain the staggered start times in pi.nix plus the time
    # an upgrade actually takes. A host whose upgrade finishes after the window
    # simply does not reboot, and carries the old kernel until the next run.
    rebootWindow = {
      lower = "03:00";
      upper = "06:00";
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
