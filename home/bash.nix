# Bash shell configuration with Starship prompt

{ pkgs, ... }:
{
  programs.bash = {
    enable = true;
    
    # Shell aliases for common commands
    shellAliases = {
      # Navigation
      ".." = "cd ..";
      "..." = "cd ../..";
      
      # Better defaults (using eza)
      ls = "eza --color=auto --icons";
      ll = "eza -la --icons --git";
      la = "eza -a --icons";
      l = "eza --icons";
      lt = "eza --tree --level=2 --icons";
      
      # Safety nets
      rm = "rm -i";
      cp = "cp -i";
      mv = "mv -i";
      
      # Modern replacements (if installed)
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
      
      # AI tools
      cc = "claude";
      
      # Misc
      c = "clear";
      h = "history";
    };
    
    # Bash-specific options
    historyControl = [ "ignoredups" "erasedups" ];
    historyFileSize = 10000;
    historySize = 10000;
    
    # Extra configuration added to .bashrc
    initExtra = ''
      # Ensure Nix profiles are in PATH
      export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
      
      # Enable Starship prompt
      eval "$(starship init bash)"
      
      # Better history search with up/down arrows
      bind '"\e[A": history-search-backward'
      bind '"\e[B": history-search-forward'
      
      # Case-insensitive tab completion
      bind 'set completion-ignore-case on'
      
      # Show all matches on ambiguous completion
      bind 'set show-all-if-ambiguous on'
      
      # Add local bin to PATH if it exists
      if [ -d "$HOME/.local/bin" ]; then
        export PATH="$HOME/.local/bin:$PATH"
      fi
      
      # Node.js global packages - use ~/.npm-global instead of read-only Nix store
      export NPM_CONFIG_PREFIX="$HOME/.npm-global"
      mkdir -p "$HOME/.npm-global/bin"
      export PATH="$HOME/.npm-global/bin:$PATH"
      
      # Cargo/Rust path
      if [ -d "$HOME/.cargo/bin" ]; then
        export PATH="$HOME/.cargo/bin:$PATH"
      fi
    '';
  };

  # Starship - modern, fast prompt
  programs.starship = {
    enable = true;
    
    settings = {
      # Prompt format
      format = "$directory$git_branch$git_status$nodejs$rust$python$nix_shell$cmd_duration$line_break$character";
      
      # Don't add newline at start of prompt
      add_newline = false;
      
      # Directory settings
      directory = {
        truncation_length = 3;
        truncate_to_repo = true;
      };
      
      # Git branch
      git_branch = {
        symbol = " ";
        style = "bold purple";
      };
      
      # Git status
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
      
      # Node.js
      nodejs = {
        symbol = " ";
        style = "bold green";
      };
      
      # Rust
      rust = {
        symbol = " ";
        style = "bold red";
      };
      
      # Python
      python = {
        symbol = " ";
        style = "bold yellow";
      };
      
      # Nix shell indicator
      nix_shell = {
        symbol = "❄️ ";
        style = "bold blue";
      };
      
      # Command duration
      cmd_duration = {
        min_time = 2000;  # Show if command takes > 2 seconds
        format = "took [$duration]($style) ";
      };
      
      # Prompt character
      character = {
        success_symbol = "[➜](bold green)";
        error_symbol = "[➜](bold red)";
      };
    };
  };
}
