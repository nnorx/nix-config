# Common profile — shell experience, editor, and basic CLI tools
# Used directly by Pi hosts, and imported by default.nix for dev hosts

{
  pkgs,
  lib,
  username,
  homeDirectory,
  ...
}:
{
  imports = [
    ./shell-common.nix # Shared aliases and PATH setup
    ./starship.nix # Prompt configuration
    ./bash.nix
    ./zsh.nix
    ./git.nix
    ./common-tools.nix # CLI essentials (ripgrep, fd, bat, eza, fzf, etc.)
    ./security.nix # vulnix + whitelist for CVE scanning
    ./tmux.nix
    ./neovim.nix
  ];

  # Let Home Manager manage itself
  programs.home-manager.enable = true;

  # User information
  home.username = username;
  home.homeDirectory = homeDirectory;

  # Records the release a host started on, not the one it runs, so it is
  # mkDefault for the same reason system.stateVersion is in hosts/common: a
  # host set up from a later release keeps its own.
  home.stateVersion = lib.mkDefault "25.11";

  # Session environment variables
  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
    PAGER = "less";
  };
}
