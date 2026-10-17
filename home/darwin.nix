# macOS-specific configuration

{ pkgs, ... }:
{
  # The night shift's work mode (docs/night-shift.md, "On a Mac").
  imports = [ ./night-shift.nix ];

  # GNU coreutils for consistent CLI behavior across platforms
  home.packages = with pkgs; [
    coreutils
  ];
}
