# System hardening and maintenance baseline for every host
{ config, ... }:
let
  # flake.nix's nixConfig must be a literal attrset, so the cache list is
  # written there and read here. Importing flake.nix reads only that attrset:
  # its inputs are not fetched and its outputs are not evaluated.
  flakeCaches = (import ../flake.nix).nixConfig;
in
{
  imports = [ ./sops-assertions.nix ];

  # Shared settings only: nothing here turns upgrades on; hosts/common/pi.nix
  # does, for the Pis. gate stays manual: an unattended switch of the routing
  # it serves would have no deploy-guard in front and no second router behind.
  system.autoUpgrade = {
    flake = "github:nnorx/nix-config";

    # A flake, not a channel.
    upgrade = false;

    flags = [
      # So an upgrade resolves exactly as `nrs` does.
      "--accept-flake-config"

      # Substitute or fail; never build on a Pi. A run that outruns cache.yml,
      # which runs off the same push to main, fails and the next night retries.
      "--max-jobs"
      "0"

      # NixOS marks the toplevel and many generated files
      # `allowSubstitutes = false`, so without this `--max-jobs 0` fails every
      # upgrade.
      "--option"
      "always-allow-substitutes"
      "true"
    ];
    allowReboot = true;

    # Catching up at boot, after a power cut, would start every Pi at once.
    persistent = false;

    # A run that finishes outside the window leaves the new generation as the
    # boot default without rebooting or switching. `lower` sits before the
    # first start in pi.nix because the unit compares HH:MM strictly.
    # Anything that must not be interrupted runs after `upper`, as
    # modules/offbox-push.nix asserts.
    rebootWindow = {
      lower = "02:30";
      upper = "06:00";
    };
  };

  # The same flake as the automatic upgrade, so the two cannot disagree about
  # where main lives. --refresh because `github:` refs are cached for an hour,
  # which would deploy a stale main. --accept-flake-config for a freshly
  # flashed host, whose nix.conf lacks the caches. nrb is for changes to the
  # interface the session runs over, which switch would pull out from under it.
  environment.shellAliases =
    let
      rebuild =
        action:
        "sudo nixos-rebuild ${action} --flake ${config.system.autoUpgrade.flake} --accept-flake-config --refresh";
    in
    {
      nrs = rebuild "switch";
      nrb = rebuild "boot";
    };

  # Keeps SD cards from filling, and bounds the generations gate's ESP holds.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  # In nix.conf as well as flake.nix, since Nix ignores client-supplied
  # settings from untrusted users, and a host that misses the cache compiles
  # the Pi 4 kernel for 9-15 hours.
  nix.settings = {
    substituters = flakeCaches.extra-substituters;
    trusted-public-keys = flakeCaches.extra-trusted-public-keys;
  };

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

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

  security.sudo = {
    execWheelOnly = true;
    wheelNeedsPassword = true;
  };

  services.timesyncd.enable = true;

  services.avahi.enable = false;

  # Capped for SD cards; gate, on NVMe, raises it.
  services.journald.extraConfig = ''
    SystemMaxUse=200M
    MaxRetentionSec=1month
  '';
}
