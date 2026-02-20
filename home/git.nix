# Git configuration

{ pkgs, ... }:
{
  programs.git = {
    enable = true;
    
    userName = "Nick";
    userEmail = "nicholas.norcross@gmail.com";
    
    # Default settings
    extraConfig = {
      # Default branch name for new repos
      init.defaultBranch = "main";
      
      # Pull strategy - rebase instead of merge
      pull.rebase = true;
      
      # Push default - push current branch to upstream
      push.default = "current";
      push.autoSetupRemote = true;
      
      # Better diffs
      diff.algorithm = "histogram";
      diff.colorMoved = "default";
      
      # Rebase settings
      rebase.autoStash = true;
      rebase.autoSquash = true;
      
      # Merge settings
      merge.conflictStyle = "diff3";
      
      # Misc
      core.editor = "nvim";
      core.autocrlf = if pkgs.stdenv.isLinux then "input" else false;
      
      # Credential helper - platform-appropriate
      credential.helper =
        if pkgs.stdenv.isDarwin
        then "osxkeychain"
        else "cache --timeout=3600";
      
      # Better log output
      log.abbrevCommit = true;
      log.date = "relative";
    };
    
    # Git aliases
    aliases = {
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
      cleanup = "!git branch --merged | grep -v '\\*\\|main\\|master' | xargs -n 1 git branch -d";
      
      # Show last commit
      last = "log -1 HEAD --stat";
      
      # List contributors
      contributors = "shortlog -sn --no-merges";
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
  programs.gh = {
    enable = true;
    settings = {
      git_protocol = "ssh";
      prompt = "enabled";
    };
  };
}
