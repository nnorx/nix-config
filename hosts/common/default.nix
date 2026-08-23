# Shared NixOS configuration for every host.
#
# Boot and storage live in pi.nix (Pis) or the host's own directory (x86), since
# those genuinely differ per platform. Everything here applies fleet-wide.
{
  pkgs,
  hostname,
  ...
}:
{
  imports = [
    ../../modules/baseline.nix
    ../../modules/ssh.nix
    ../../modules/firewall.nix
    ../../modules/fail2ban.nix
  ];

  system.stateVersion = "25.11";

  # Locale and timezone
  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  # Networking
  networking.useDHCP = false;

  # User account — hostname doubles as username (core3, core4, core5)
  users.users.${hostname} = {
    isNormalUser = true;
    initialPassword = "changeme"; # Change on first login with: passwd
    extraGroups = [
      "wheel"
    ];
    shell = pkgs.zsh;
  };

  # Zsh must be enabled system-wide for it to work as a login shell
  programs.zsh.enable = true;

  # Minimal set of system packages
  environment.systemPackages = with pkgs; [
    git
    vim
    curl
    htop
  ];
}
