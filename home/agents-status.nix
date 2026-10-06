# agents-status shows where each branch of a batch of background agents
# stands: handoff, PR and checks, and which branches conflict with main or
# with each other. `claude agents` shows the agents themselves; this is for
# deciding what to review and merge next, in the order a plan from the core
# plugin's dispatch skill set when there is one.
{ config, pkgs, ... }:
{
  home.packages = [
    (pkgs.writeShellApplication {
      name = "agents-status";
      # GNU findutils and coreutils for find -printf and the rest on the Mac.
      runtimeInputs = [
        config.programs.gh.package
        pkgs.git
        pkgs.jq
        pkgs.curl
        pkgs.coreutils
        pkgs.findutils
        pkgs.gnused
      ];
      text = builtins.readFile ./agents-status.sh;
    })
  ];
}
