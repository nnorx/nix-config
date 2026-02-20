# Development tools and programming languages

{ pkgs, unstable, ... }:
{
  home.packages = with pkgs; [
    # ===== CLI Essentials =====
    ripgrep       # Fast grep replacement (rg)
    fd            # Fast find replacement
    jq            # JSON processor
    yq            # YAML processor
    bat           # Cat with syntax highlighting
    eza           # Modern ls replacement
    fzf           # Fuzzy finder
    tree          # Directory tree view
    htop          # Process viewer
    ncdu          # Disk usage analyzer
    wget          # File downloader
    curl          # HTTP client
    unzip         # Archive extraction
    
    # ===== JavaScript/TypeScript =====
    nodejs_22     # Node.js LTS (includes npm)
    unstable.pnpm # pnpm 10 from nixpkgs-unstable
    nodePackages.typescript
    nodePackages.typescript-language-server
    
    # ===== Rust =====
    rustc         # Rust compiler
    cargo         # Rust package manager
    rustfmt       # Rust formatter
    clippy        # Rust linter
    rust-analyzer # Rust LSP
    
    # ===== Git Tools =====
    lazygit         # Git TUI
    
    # ===== DevOps Tools =====
    docker-client   # Docker CLI
    docker-compose  # Docker orchestration
    kubectl         # Kubernetes CLI
    k9s             # Kubernetes TUI
    
    # ===== Language Servers & Formatters =====
    nil             # Nix LSP
    nixfmt-rfc-style # Nix formatter
    
    # ===== Misc Development =====
    gnumake       # Make build tool
    gcc           # C compiler (needed for some builds)
    direnv        # Per-directory environment variables
    
    # ===== AI Tools =====
    claude-code       # Claude Code CLI (run `claude` to authenticate)
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
    historyWidgetOptions = [ "--sort" "--exact" ];
  };

  # Direnv - automatic environment switching
  programs.direnv = {
    enable = true;
    enableBashIntegration = true;
    enableZshIntegration = true;
    nix-direnv.enable = true;  # Better Nix integration
  };

  # Zoxide - smarter cd command
  programs.zoxide = {
    enable = true;
    enableBashIntegration = true;
    enableZshIntegration = true;
  };
}
