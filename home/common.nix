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
    ./tmux.nix
    ./neovim.nix
  ];

  # Let Home Manager manage itself
  programs.home-manager.enable = true;

  # User information
  home.username = username;
  home.homeDirectory = homeDirectory;

  # This should match the Home Manager release you're using
  home.stateVersion = "24.11";

  # Session environment variables
  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
    PAGER = "less";
  };
}
