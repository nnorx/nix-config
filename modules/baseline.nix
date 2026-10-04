# System hardening and maintenance baseline for every host
{ config, ... }:
let
  # flake.nix's nixConfig has to be a literal attrset there, but nothing stops
  # another file importing the flake and reading it, so the cache list is
  # written once. Importing flake.nix only reads its top-level attrset; its
  # inputs are not fetched and its outputs are not evaluated.
  flakeCaches = (import ../flake.nix).nixConfig;
in
{
  # Automatic NixOS upgrades from the flake. Shared settings only: nothing here
  # turns them on. hosts/common/pi.nix does, for the Pis and nothing else.
  #
  # gate stays manual. With allowReboot the nixpkgs unit reboots only when the
  # kernel, its modules or the initrd changed, and otherwise runs `switch`. On
  # gate that is an unattended switch of the routing it is serving, with no
  # deploy-guard in front of it and no second router behind it. A Pi that goes
  # wrong is a card pull.
  system.autoUpgrade = {
    flake = "github:nnorx/nix-config";

    # A flake, not a channel, so `--upgrade` would do nothing but update the
    # root `nixos` channel the Pi images still carry, and warn about it.
    upgrade = false;

    flags = [
      # Redundant with nix.settings below, which already puts the caches in
      # nix.conf. Kept so an upgrade resolves exactly as `nrs` does.
      "--accept-flake-config"

      # Substitute or fail; never build on the host. A Pi 4 kernel is in no
      # public cache and takes 9-15 hours to compile there, and cache.yml,
      # which fills our own cache, runs off the same push to main that an
      # upgrade picks up. A run that outruns it fails and the next night
      # retries. The cost: a host that has quietly stopped upgrading looks like
      # one with nothing to do, until the wrong-boot detection in
      # docs/router.md exists.
      "--max-jobs"
      "0"

      # Without this, the flag above fails every upgrade. NixOS marks the system
      # toplevel, etc and hundreds of small generated files such as unit
      # definitions `allowSubstitutes = false`, and stock Nix honours that, so
      # they can only be built locally, which `--max-jobs 0` forbids. Every
      # commit changes the toplevel. A dry run of lifeline's system for 163bb57
      # lists 255 derivations to build without this and none with it: cache.yml
      # builds and pushes exactly those paths, so they are there to fetch.
      "--option"
      "always-allow-substitutes"
      "true"
    ];
    allowReboot = true;

    # A run that misses its slot, typically because the rack lost power, waits
    # for the next night instead of firing at boot. Catching up at boot would
    # start every Pi's upgrade at once, undoing the stagger in pi.nix, and
    # possibly before a resolver's own AdGuard is serving.
    persistent = false;

    # Contains the start times in pi.nix plus the time a run takes.
    #
    # A run that finishes outside it does nothing further. The new generation
    # is already the boot default, but the host neither reboots nor switches,
    # and runs the old generation until a later run lands inside the window or
    # something else reboots it.
    #
    # The lower bound sits before the first start rather than on it. The unit
    # compares HH:MM strings strictly, so a run finishing inside its own start
    # minute would otherwise count as outside.
    #
    # Anything that must not be interrupted by a reboot runs after `upper`.
    # modules/offbox-push.nix asserts that it does.
    rebootWindow = {
      lower = "02:30";
      upper = "06:00";
    };
  };

  # Deploy shortcuts, on every host built from this flake, forge included.
  # They deploy what the automatic upgrade does, from the same flake, so the two
  # cannot disagree about where main lives. nixos-rebuild resolves the flake
  # attribute from the hostname when #name is omitted, so one string is correct
  # on every host.
  #
  # --refresh matters: `github:` refs are cached for an hour by default, so
  # without it you can silently deploy a stale main. --accept-flake-config is
  # redundant once nix.settings below has put the caches in nix.conf, but is
  # still needed on a freshly flashed host, and costs nothing here.
  #
  # nrb (boot) is for changes that reconfigure the interface you are connected
  # over, such as a static IP moving or gate's routing, where switch would pull
  # the network out from under the session mid-activation.
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

  # Nix garbage collection — keeps SD cards from filling up, and bounds how
  # many generations gate's ESP has to hold
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  # Binary caches, baked into each host's nix.conf so they apply to every user
  # and every nix invocation. flake.nix's nixConfig declares them too, but that
  # form is client-supplied: Nix ignores it for anyone outside trusted-users,
  # and only honours it with --accept-flake-config. Relying on it alone means a
  # host silently compiles instead of substituting, which for linux_rpi4 is
  # 9-15 hours on a Pi 4. So the list is read from there and written here.
  nix.settings = {
    substituters = flakeCaches.extra-substituters;
    trusted-public-keys = flakeCaches.extra-trusted-public-keys;
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
