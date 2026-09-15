# Home Assistant, natively rather than in a container.
#
# The opposite call to modules/unifi.nix, for the opposite reasons. Home
# Assistant is free software that Hydra builds, so the nixpkgs module gets a
# declarative config, no Docker in the path and a closure CI can cache. None of
# that was on offer for UniFi.
#
# The package comes from `unstable`, and not for novelty. core5 evaluates
# against nixos-raspberrypi's nixpkgs, which replaces ffmpeg with Raspberry Pi's
# fork. Home Assistant and several of its Python dependencies link
# ffmpeg, so on core5's own package set each of them is a derivation
# cache.nixos.org has never seen, and CI would rebuild the lot. `unstable` is
# imported without that overlay, so its build is Hydra's. Checked 2026-09-14:
# core5's own `home-assistant` (2026.5.4) was absent from cache.nixos.org and
# unstable's (2026.7.4) was present.
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
  net,
  unstable,
  ...
}:
let
  inherit (config.services.home-assistant) configDir;
in
{
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

      # Govee bulbs over their local LAN API, no cloud account. Discovery is
      # multicast, so it only finds bulbs on a segment core5 has an address on.
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
