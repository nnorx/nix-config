# Framework Laptop 16 (Ryzen AI 9 HX 370, RTX 5070 module). Nick's laptop.
#
# The one host that is not a server, so it does not import hosts/common: that
# file names the user after the host, pins a static address from lib/net.nix,
# and makes SSH the only way in. None of that fits a machine with a keyboard
# that roams between networks. What the fleet genuinely shares, nix settings,
# caches, gc, sysctl and sudo, is modules/baseline.nix, imported below.
#
# Hardware support comes from nixos-hardware's
# framework-16-amd-ai-300-series-nvidia, added in flake.nix. See
# docs/laptop.md for the install and the Secure Boot bootstrap.
{
  config,
  pkgs,
  lib,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
    ./boot.nix
    ./graphics.nix
    ./desktop.nix
    ../../modules/baseline.nix
  ];

  # NVIDIA's driver and Steam.
  nixpkgs.config.allowUnfree = true;

  # Installed from 26.05, like gate.
  system.stateVersion = "26.05";
  home-manager.users.nick.home.stateVersion = "26.05";

  # Same as hosts/common.
  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  # NetworkManager rather than the fleet's static addressing: this host joins
  # whatever network it is on. No sshd, so the firewall opens nothing. After
  # the install nothing deploys to this box from elsewhere; it rebuilds itself.
  networking = {
    hostName = "forge";
    networkmanager.enable = true;
    firewall.enable = true;
  };

  # sops, as on the fleet: the age key is derived from the SSH host key. There
  # is no sshd here to generate one, so the key is created before the install
  # and placed by nixos-anywhere's --extra-files. That is what lets the
  # recipient be in .sops.yaml before first activation, which docs/recovery.md
  # explains is required. With no sshd, nothing ever regenerates it either.
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  sops.defaultSopsFile = ../../secrets/forge.yaml;
  sops.secrets.user-password-hash.neededForUsers = true;

  # Declarative users, for the same reasons as hosts/common, where the costs
  # are spelled out. The password is also the sudo password and the one SDDM
  # asks for; the disk passphrase is separate.
  users.mutableUsers = false;
  users.users.nick = {
    isNormalUser = true;
    hashedPasswordFile = config.sops.secrets.user-password-hash.path;
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
    shell = pkgs.zsh;
  };
  programs.zsh.enable = true;

  # Both are already defaults from nixos-hardware. Stated so the choice is
  # visible here: power-profiles-daemon is Framework's recommendation on AMD,
  # and enabling it is what keeps nixos-hardware from turning TLP on.
  services.power-profiles-daemon.enable = true;
  services.fwupd.enable = true;

  # nrs/nrb match the fleet's: deploy main from GitHub. The attribute is
  # resolved from the hostname.
  environment.shellAliases = {
    nrs = "sudo nixos-rebuild switch --flake github:nnorx/nix-config --accept-flake-config --refresh";
    nrb = "sudo nixos-rebuild boot --flake github:nnorx/nix-config --accept-flake-config --refresh";
  };

  # `hms` elsewhere runs standalone Home Manager, which here would find the
  # WSL `homeConfigurations.nick` by username and fight the embedded copy over
  # the same files. On this host Home Manager is part of the system, so `hms`
  # rebuilds the system from the local checkout instead: the way to try a
  # branch before it reaches main.
  home-manager.users.nick.shell-common.aliases.hms =
    lib.mkForce "sudo nixos-rebuild switch --flake ~/projects/nix-config --accept-flake-config";

  environment.systemPackages = with pkgs; [
    git
    sbctl # Secure Boot keys; see boot.nix
    pciutils # lspci, for the PRIME bus IDs in graphics.nix
  ];
}
