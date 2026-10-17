# fleet-deploy deploys main to the Pis by day, one at a time, through each
# Pi's deploy login (modules/deploy-agent.nix): preflight's brief against what
# the host runs, a confirmation, a wait for cache.yml, the upgrade, and the
# reboot a staged kernel needs. ./fleet-deploy.sh has the steps.
#
# Linux only, like ./ssh.nix, since the admin machines are, and its logins go
# through the fleet entries that file writes. It needs the network to the Pis,
# so in Claude Code's sandbox it reaches nothing, and deploying stays Nick's.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  home.packages = lib.optionals pkgs.stdenv.isLinux [
    (pkgs.writeShellApplication {
      name = "fleet-deploy";
      # nix and git are the ones on PATH, as for preflight, so they talk to
      # the daemon and the checkout the way everything else on the machine
      # does.
      runtimeInputs = with pkgs; [
        coreutils
        curl
        gawk
        gnused
        jq
        openssh
      ];
      runtimeEnv.FLEET_DEPLOY_KEY = "${config.home.homeDirectory}/.ssh/id_ed25519_deploy";
      text = builtins.readFile ./fleet-deploy.sh;
    })
  ];
}
