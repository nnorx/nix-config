# Docker daemon with automatic cleanup
{ pkgs, ... }:
{
  virtualisation.docker = {
    enable = true;
    package = pkgs.docker_29;
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
    storageDriver = "overlay2";
  };
}
