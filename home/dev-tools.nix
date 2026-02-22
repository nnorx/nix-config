# Development tools and programming languages
# Only included on dev hosts (WSL, macOS) — not on Raspberry Pis
# CLI essentials live in common-tools.nix

{
  pkgs,
  lib,
  unstable,
  ...
}:
{
  home.packages = with pkgs; [
    # ===== JavaScript/TypeScript =====
    nodejs_22 # Node.js LTS (includes npm)
    unstable.pnpm # pnpm 10 from nixpkgs-unstable
    nodePackages.typescript
    nodePackages.typescript-language-server

    # ===== Rust =====
    rustc # Rust compiler
    cargo # Rust package manager
    rustfmt # Rust formatter
    clippy # Rust linter
    rust-analyzer # Rust LSP

    # ===== Git Tools =====
    lazygit # Git TUI

    # ===== DevOps Tools =====
    docker-client # Docker CLI
    docker-compose # Docker orchestration
    kubectl # Kubernetes CLI
    k9s # Kubernetes TUI

    # ===== Language Servers & Formatters =====
    nil # Nix LSP
    nixfmt-rfc-style # Nix formatter

    # ===== Misc Development =====
    gnumake # Make build tool
    gcc # C compiler (needed for some builds)
    direnv # Per-directory environment variables
  ];

  # Dev-specific shell aliases (merged with common aliases via module system)
  shell-common.aliases = {
    # Git TUI
    lg = "lazygit";

    # Package manager
    pn = "pnpm";

    # AI tools
    cc = "claude";

    # Playwright
    pwt = "npx playwright test";
    pwth = "npx playwright test --headed";
    pwtd = "npx playwright test --debug";
    pwui = "npx playwright test --ui";
    pwshow = "npx playwright show-report";
    pwgen = "npx playwright codegen";
  };

  # Dev-specific session variables
  home.sessionVariables = {
    # Skip Playwright browser downloads - use Nix-provided browsers in devShells
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
  };

  # Dev-specific directory setup
  home.activation.createNpmGlobalDir = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p "$HOME/.npm-global/bin"
  '';

  # Direnv - automatic environment switching
  programs.direnv = {
    enable = true;
    enableBashIntegration = true;
    enableZshIntegration = true;
    nix-direnv.enable = true; # Better Nix integration
  };
}
