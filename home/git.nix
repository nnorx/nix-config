# Git configuration

{ pkgs, ... }:
{
  programs.git = {
    enable = true;

    # Git settings (25.11 unified settings format)
    settings = {
      user = {
        name = "Nick";
        email = "nicholas.norcross@gmail.com";
      };

      # Default branch name for new repos
      init.defaultBranch = "main";

      # Pull strategy - rebase instead of merge
      pull.rebase = true;

      # Push default - push current branch to upstream
      push.default = "current";
      push.autoSetupRemote = true;

      # Merged PRs have their branches deleted, so prune the leftover
      # origin/<branch> refs on every fetch.
      fetch.prune = true;

      # Better diffs
      diff.algorithm = "histogram";
      diff.colorMoved = "default";

      # Rebase settings
      rebase.autoStash = true;
      rebase.autoSquash = true;

      # Merge settings
      merge.conflictStyle = "diff3";

      # Misc
      core.editor = "nano";
      core.autocrlf = if pkgs.stdenv.isLinux then "input" else false;

      # Credential helper - platform-appropriate
      credential.helper = if pkgs.stdenv.isDarwin then "osxkeychain" else "cache --timeout=3600";

      # Better log output
      log.abbrevCommit = true;
      log.date = "relative";

      # Git aliases
      alias = {
        # Status shortcuts
        s = "status -sb";
        st = "status";

        # Log variants
        lg = "log --oneline --graph --decorate -20";
        lga = "log --oneline --graph --decorate --all -30";
        ll = "log --pretty=format:'%C(yellow)%h%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' -20";

        # Diff shortcuts
        d = "diff";
        ds = "diff --staged";
        dc = "diff --cached";

        # Commit shortcuts
        c = "commit";
        cm = "commit -m";
        ca = "commit --amend";
        can = "commit --amend --no-edit";

        # Branch shortcuts
        b = "branch";
        ba = "branch -a";
        bd = "branch -d";
        bD = "branch -D";

        # Checkout/Switch shortcuts
        co = "checkout";
        sw = "switch";
        swc = "switch -c";

        # Stash shortcuts
        ss = "stash";
        sp = "stash pop";
        sl = "stash list";

        # Reset shortcuts
        unstage = "reset HEAD --";
        uncommit = "reset --soft HEAD~1";

        # Remote shortcuts
        f = "fetch --all --prune";
        p = "push";
        pf = "push --force-with-lease";
        pl = "pull";

        # Useful combos
        sync = "!git fetch --all --prune && git pull --rebase";

        # Deletes local branches whose remote branch is gone. Not `branch
        # --merged`: PRs are squash-merged, so a merged branch is never an
        # ancestor of main and that never matched one. -D for the same
        # reason, since git cannot tell such a branch was merged. A branch
        # that was never pushed has no upstream and is left alone.
        cleanup = "!git fetch --prune && git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads | awk '$2 == \"[gone]\" { print $1 }' | while read -r b; do git branch -D \"$b\"; done";

        # Show last commit
        last = "log -1 HEAD --stat";

        # List contributors
        contributors = "shortlog -sn --no-merges";
      };
    };

    # Global gitignore
    ignores = [
      # OS files
      ".DS_Store"
      "Thumbs.db"

      # Editor files
      "*.swp"
      "*.swo"
      "*~"
      ".vscode/"
      ".idea/"

      # Environment files (be careful with these)
      ".env"
      ".env.local"
      ".env.*.local"

      # Build outputs
      "node_modules/"
      "__pycache__/"
      "*.pyc"
      "target/"
      "dist/"
      "build/"

      # Nix
      "result"
      "result-*"

      # Playwright
      "test-results/"
      "playwright-report/"
      "blob-report/"
      ".playwright/"

      # tmux logs
      "tmux-*.log"
    ];
  };

  # GitHub CLI
  #
  # Home Manager's gh module also makes `gh auth git-credential` git's helper
  # for github.com (gitCredentialHelper, on by default), so HTTPS pushes use
  # gh's token and no machine needs a GitHub SSH key. The cache helper above
  # only serves other hosts.
  programs.gh = {
    enable = true;
    settings = {
      # https on Linux, matching that helper; forge has no GitHub SSH key, so
      # ssh here would break `gh repo clone`. macOS keeps ssh. `gh auth login`
      # also stores a protocol per host, which overrides this for that host.
      git_protocol = if pkgs.stdenv.isDarwin then "ssh" else "https";
      prompt = "enabled";
    };
  };
}
