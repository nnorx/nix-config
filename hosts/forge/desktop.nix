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

  programs.firefox.enable = true;

  # From unstable, where browser security releases land first.
  environment.systemPackages = [ unstable.brave ];

  # Carries Cascadia Code NF, which the starship prompt's icons need. Select it
  # as the terminal font.
  fonts.packages = [ pkgs.cascadia-code ];
}
