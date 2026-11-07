# Home Assistant, natively rather than in a container.
#
# The opposite call to modules/unifi.nix, for the opposite reasons. Home
# Assistant is free software that Hydra builds, so the nixpkgs module gets a
# declarative config, no Docker in the path and a closure CI can cache. None of
# that was on offer for UniFi.
#
# The package comes from `unstable`, and not for novelty. core5's package set
# carries nixos-raspberrypi's overlays, one of which replaces ffmpeg with
# Raspberry Pi's fork. Home Assistant and several of its Python dependencies link
# ffmpeg, so on core5's own package set each of them is a derivation
# cache.nixos.org has never seen, and CI would rebuild the lot. `unstable` is
# imported without that overlay, so its build is Hydra's. Checked 2026-10-03:
# core5's own `home-assistant` (2026.5.4) was absent from cache.nixos.org and
# unstable's (2026.9.4) was present.
#
# The cost is that `unstable` moves with every flake.lock bump, and the
# automatic upgrade applies it unattended. The recorder's schema migrations are
# one-way, which is the trap modules/unifi.nix describes: a generation rollback
# after a migration faces a newer database with an older binary. See
# docs/home-assistant.md before rolling core5 back past an upgrade.
#
# Integrations, devices, users, dashboards and UI-made automations are not
# declarative. They live in /var/lib/hass and are state.
{
  config,
  lib,
  net,
  unstable,
  ...
}:
let
  inherit (config.services.home-assistant) configDir;

  # Upstream's decoder fix ("Detect and report invalid stream earlier",
  # released in brotli 1.2.1), on unstable's brotli 1.2.0. vulnix reads the
  # CVE ID from the patch's name.
  brotliWithDecoderFix = unstable.brotli.overrideAttrs (old: {
    patches = old.patches ++ [
      (unstable.fetchpatch {
        name = "CVE-2026-111497.patch";
        url = "https://github.com/google/brotli/commit/b418fa81c48262a86a95332b0bc6d62c30aa78b6.patch";
        hash = "sha256-sZn5DP5l1B7b/clxq+kj925eti7lQ2nrv6Wuhl2bMw4=";
      })
    ];
  });
in
{
  # Home Assistant's process loads the fixed library ahead of unstable's
  # brotli, until the channel ships 1.2.1 and this retires itself.
  #
  # Unstable's python brotli and brotlicffi, and whatever else in the process
  # links brotli, find `libbrotli*.so.1` through their RUNPATH, which the
  # loader searches after LD_LIBRARY_PATH. Building them against the fixed
  # library instead would rebuild aiohttp and most of Home Assistant above it,
  # and rewriting the closure with system.replaceDependencies needs an aarch64
  # builder just to evaluate core5. Nothing else sets LD_LIBRARY_PATH for the
  # service, not the nixpkgs module nor the package's wrapper, and a second
  # definition would fail evaluation on the conflict rather than replace this.
  #
  # The fix adds an error code in a slot the header had reserved, so the
  # library's ABI is unchanged. Processes Home Assistant starts inherit the
  # variable too; the library needs only long-standing glibc symbols, so one
  # built on stable's older glibc loads it as well.
  systemd.services.home-assistant.environment =
    lib.mkIf (lib.versionOlder unstable.brotli.version "1.2.1")
      {
        LD_LIBRARY_PATH = "${brotliWithDecoderFix.lib}/lib";
      };

  services.home-assistant = {
    enable = true;

    # `doInstallCheck = false` is what the module's own default does. Setting
    # `package` replaces that default, and without the override every rebuild
    # runs Home Assistant's full test suite.
    package = unstable.home-assistant.overrideAttrs (_: {
      doInstallCheck = false;
    });

    # Setting this replaces the module's list, so its defaults are restated
    # first. An integration added in the UI but missing here fails at setup
    # with a missing Python module.
    extraComponents = [
      "default_config"
      "met"
      "esphome"
      "rpi_power"

      # Govee lights over their local LAN API, no cloud in the path. Discovery
      # is multicast and the lights are on iot, where core5 has no address, so
      # gate routes the scan across: hosts/gate/govee.nix.
      "govee_light_local"
    ];

    config = {
      default_config = { };

      # Home Assistant treats the presence of *any* core key here as "location
      # is configured in YAML" and locks the editor in the UI. The module fills
      # in time_zone from `time.timeZone`, which alone would do it, and would
      # leave YAML as the only place to set the house's coordinates: this
      # public repo. Nulled, every key is absent, and location is set during
      # onboarding and kept in .storage.
      homeassistant.time_zone = null;

      # From lib/net.nix, which the host's firewall rule reads too.
      http.server_port = net.ports.homeAssistant;

      "automation ui" = "!include automations.yaml";
      "scene ui" = "!include scenes.yaml";
      "script ui" = "!include scripts.yaml";
    };
  };

  # Home Assistant will not start if an `!include` target is missing. `f`
  # creates each file once and never touches it again, seeded the way Home
  # Assistant's own first run seeds them.
  systemd.tmpfiles.rules = [
    "f ${configDir}/automations.yaml 0644 hass hass - []"
    "f ${configDir}/scenes.yaml 0644 hass hass -"
    "f ${configDir}/scripts.yaml 0644 hass hass -"
  ];
}
