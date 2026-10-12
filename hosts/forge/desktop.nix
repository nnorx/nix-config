# Plasma 6 on Wayland, audio, and games.
{ pkgs, unstable, ... }:
{
  services.desktopManager.plasma6.enable = true;
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };

  # Plasma's defaults, trimmed of what this laptop has no use for. Measured
  # against the system closure on 2026-10-10:
  #
  # - Orca, the screen reader, and speech-dispatcher, which every NixOS desktop
  #   enables and whose 645 MiB of mbrola voices are most of the 0.74 GiB.
  #   Without it, Firefox's Read Aloud and Okular's speech have no voice.
  # - KDE PIM is Akonadi and the MariaDB server it stores mail and calendars
  #   in, 0.37 GiB. Nothing here uses KMail, Kontact or Merkuro, and Akonadi
  #   had never started.
  # - ModemManager probes for cellular modems, which a Framework 16 does not
  #   have. Re-enable it for a USB LTE dongle.
  # - The touch keyboard: the panel is not a touchscreen.
  services.orca.enable = false;
  services.speechd.enable = false;
  programs.kde-pim.enable = false;
  networking.modemmanager.enable = false;
  environment.plasma6.excludePackages = with pkgs.kdePackages; [
    plasma-keyboard
    qtvirtualkeyboard
  ];

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  hardware.bluetooth.enable = true;

  # Backs the "use dedicated GPU" launch options in Plasma and Steam, so a game
  # can go to the RTX module without editing its launch command.
  services.switcherooControl.enable = true;

  # Steam, with Proton from Valve plus Proton-GE as an extra compatibility tool.
  # Remote Play and LAN game transfers would open firewall ports, so they stay
  # off until wanted.
  programs.steam = {
    enable = true;
    extraCompatPackages = [ pkgs.proton-ge-bin ];
  };
  programs.gamemode.enable = true;

  # Enterprise policies, which about:policies lists. docs/privacy.md, "forge",
  # has what each one stops.
  programs.firefox = {
    enable = true;
    policies = {
      DisableTelemetry = true;
      DisableFirefoxStudies = true;

      # Off, so every lookup goes through the system resolver: AdGuard at home
      # and over the tunnel. Firefox checks AdGuard's canary answer only in its
      # automatic rollout, which never runs while any policy is set, so the
      # alternative to off is DoH everywhere, home included. Encrypting DNS
      # away from home is the system resolver's job, for every application.
      DNSOverHTTPS = {
        Enabled = false;
        Locked = true;
      };
    };

    # No policy covers crash reports. These become locked prefs through the
    # Preferences policy. The dialog shown after the whole browser crashes
    # keeps its own checkbox, which no pref reaches.
    preferences = {
      # Send pending reports without asking, after a tab crash or at startup.
      "browser.crashReports.unsubmittedCheck.autoSubmit2" = false;
      # The bar offering to send reports left from earlier crashes.
      "browser.crashReports.unsubmittedCheck.enabled" = false;
      # The crashed-tab page's "send a report" box, ticked by default.
      "browser.tabs.crashReporting.sendReport" = false;
    };
  };

  # From unstable, where browser security releases land first.
  environment.systemPackages = [ unstable.brave ];

  # Carries Cascadia Code NF, which the starship prompt's icons need. Select it
  # as the terminal font.
  fonts.packages = [ pkgs.cascadia-code ];
}
