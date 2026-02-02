# Main Home Manager configuration
# This file imports all modules and sets core options

{ pkgs, lib, username, homeDirectory, ... }:
{
  imports = [
    ./shell-common.nix  # Shared aliases, PATH setup, and starship config
    ./bash.nix
    ./zsh.nix
    ./git.nix
    ./dev-tools.nix
    ./tmux.nix
    ./neovim.nix
  ];

  # Let Home Manager manage itself
  programs.home-manager.enable = true;

  # User information
  home.username = username;
  home.homeDirectory = homeDirectory;

  # This should match the Home Manager release you're using
  # Don't change this after initial setup without reading the docs
  home.stateVersion = "24.11";

  # Session environment variables
  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
    PAGER = "less";
  };

  # Create directories once during activation (not on every shell start)
  home.activation.createNpmGlobalDir = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p "$HOME/.npm-global/bin"
  '';
}
