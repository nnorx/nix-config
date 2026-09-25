# Plasma 6 on Wayland, audio, and games.
{ pkgs, ... }:
{
  services.desktopManager.plasma6.enable = true;
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };

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

  # Carries Cascadia Code NF, which the starship prompt's icons need. Select it
  # as the terminal font.
  fonts.packages = [ pkgs.cascadia-code ];
}
