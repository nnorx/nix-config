# pr-handoff publishes a PR that Claude Code prepared. Commands in its sandbox
# have no GitHub login (CLAUDE.md, "Deploying and merging"), so Claude writes
# the title and body to .git/pr-handoff/<branch>.md and Nick runs this. It
# shows what it is about to publish and asks first, because the text goes out
# public and under Nick's name. The core plugin's pr-handoff skill is the
# other half: how Claude writes those files.
{ config, pkgs, ... }:
{
  home.packages = [
    (pkgs.writeShellApplication {
      name = "pr-handoff";
      runtimeInputs = [
        config.programs.gh.package
        pkgs.git
        pkgs.coreutils
        pkgs.gnused
        pkgs.gnugrep
      ];
      text = builtins.readFile ./pr-handoff.sh;
    })
  ];

  shell-common.aliases = {
    ph = "pr-handoff";
    phm = "pr-handoff merge";
  };
}
