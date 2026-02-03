# Shared shell configuration used by both bash.nix and zsh.nix
# This avoids duplication of aliases and common settings

{ pkgs, lib, ... }:
let
  # Shared aliases for all shells
  commonAliases = {
    # Navigation
    ".." = "cd ..";
    "..." = "cd ../..";
    
    # Better defaults (using eza)
    ls = "eza --color=auto";
    ll = "eza -la --git";
    la = "eza -a";
    l = "eza";
    lt = "eza --tree --level=2";
    
    # Safety nets
    rm = "rm -i";
    cp = "cp -i";
    mv = "mv -i";
    
    # Modern replacements
    cat = "bat --paging=never";
    grep = "rg";
    find = "fd";
    
    # Git shortcuts
    gs = "git status";
    gd = "git diff";
    gl = "git log --oneline -20";
    lg = "lazygit";
    
    # Nix shortcuts
    nrs = "nix run home-manager -- switch --flake";
    nfu = "nix flake update";
    ngc = "nix-collect-garbage --delete-older-than 30d";
    
    # AI tools
    cc = "claude";
    
    # Misc
    c = "clear";
    h = "history";
  };

  # Common PATH setup (POSIX-compatible, works in both bash and zsh)
  commonPathSetup = ''
    # Ensure Nix profiles are in PATH
    export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
    
    # Add local bin to PATH if it exists
    if [ -d "$HOME/.local/bin" ]; then
      export PATH="$HOME/.local/bin:$PATH"
    fi
    
    # Node.js global packages - use ~/.npm-global instead of read-only Nix store
    export NPM_CONFIG_PREFIX="$HOME/.npm-global"
    export PATH="$HOME/.npm-global/bin:$PATH"
    
    # Cargo/Rust path
    if [ -d "$HOME/.cargo/bin" ]; then
      export PATH="$HOME/.cargo/bin:$PATH"
    fi
  '';
in
{
  # Export these as module options so other files can use them
  options.shell-common = {
    aliases = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = commonAliases;
      description = "Common shell aliases shared between bash and zsh";
    };
    
    pathSetup = lib.mkOption {
      type = lib.types.str;
      default = commonPathSetup;
      description = "Common PATH setup script";
    };
  };

  # Starship prompt configuration (shared between shells)
  config.programs.starship = {
    enable = true;
    
    settings = {
      format = "$directory$git_branch$git_status$nodejs$rust$python$nix_shell$cmd_duration$line_break$character";
      add_newline = false;
      
      directory = {
        truncation_length = 3;
        truncate_to_repo = true;
      };
      
      git_branch = {
        symbol = "git:";
        style = "bold purple";
      };
      
      git_status = {
        conflicted = "⚔️ ";
        ahead = "⬆️ ";
        behind = "⬇️ ";
        diverged = "↕️ ";
        untracked = "?";
        stashed = "📦 ";
        modified = "!";
        staged = "+";
        renamed = "»";
        deleted = "✘";
      };
      
      nodejs = {
        symbol = "node ";
        style = "bold green";
      };
      
      rust = {
        symbol = "rs ";
        style = "bold red";
      };
      
      python = {
        symbol = "py ";
        style = "bold yellow";
      };
      
      nix_shell = {
        symbol = "❄️ ";
        style = "bold blue";
      };
      
      cmd_duration = {
        min_time = 2000;
        format = "took [$duration]($style) ";
      };
      
      character = {
        success_symbol = "[>](bold green)";
        error_symbol = "[>](bold red)";
      };
    };
  };
}
