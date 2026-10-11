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
        pkgs.less # the `d` answer pages the diff
      ];
      text = builtins.readFile ./pr-handoff.sh;
    })
  ];

  shell-common.aliases = {
    ph = "pr-handoff";
    phm = "pr-handoff merge";
    # What this branch adds since it left the default branch, which is what
    # its PR shows. Three dots: from where they diverged, so commits merged to
    # main since then do not show up reversed. origin/HEAD rather than main,
    # since not every repo's default branch is main.
    phd = "git diff origin/HEAD...";
    phds = "git diff --stat origin/HEAD...";
  };
}
