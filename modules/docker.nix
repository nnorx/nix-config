# Docker daemon with automatic cleanup
{ ... }:
{
  virtualisation.docker = {
    enable = true;
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
    storageDriver = "overlay2";
  };
}
