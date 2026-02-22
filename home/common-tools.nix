# Common CLI tools shared across all hosts
# These are the everyday essentials - no dev languages or devops tools

{ pkgs, ... }:
{
  home.packages = with pkgs; [
    # ===== CLI Essentials =====
    ripgrep # Fast grep replacement (rg)
    fd # Fast find replacement
    jq # JSON processor
    yq # YAML processor
    bat # Cat with syntax highlighting
    eza # Modern ls replacement
    fzf # Fuzzy finder
    tree # Directory tree view
    htop # Process viewer
    ncdu # Disk usage analyzer
    wget # File downloader
    curl # HTTP client
    unzip # Archive extraction
    tldr # Community-maintained command cheat sheets
  ];

  # FZF - fuzzy finder integration
  programs.fzf = {
    enable = true;
    enableBashIntegration = true;
    enableZshIntegration = true;

    # Use fd for faster file finding
    defaultCommand = "fd --type f --hidden --follow --exclude .git";

    # Ctrl+T to find files
    fileWidgetCommand = "fd --type f --hidden --follow --exclude .git";
    fileWidgetOptions = [ "--preview 'bat --color=always --style=numbers --line-range=:500 {}'" ];

    # Alt+C to cd into directories
    changeDirWidgetCommand = "fd --type d --hidden --follow --exclude .git";
    changeDirWidgetOptions = [ "--preview 'tree -C {} | head -200'" ];

    # Ctrl+R for history (default)
    historyWidgetOptions = [
      "--sort"
      "--exact"
    ];
  };

  # Zoxide - smarter cd command
  programs.zoxide = {
    enable = true;
    enableBashIntegration = true;
    enableZshIntegration = true;
  };
}
