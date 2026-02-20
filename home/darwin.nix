# macOS-specific configuration

{ pkgs, ... }:
{
  # GNU coreutils for consistent CLI behavior across platforms
  home.packages = with pkgs; [
    coreutils
  ];
}
