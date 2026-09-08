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
    nodejs_24 # Node.js 24 (includes npm)
    unstable.pnpm # pnpm 10 from nixpkgs-unstable
    typescript # was nodePackages.typescript; that set was removed in 26.05

    # ===== Rust =====
    rustc # Rust compiler
    cargo # Rust package manager
    rustfmt # Rust formatter
    clippy # Rust linter

    # ===== Git Tools =====
    git-crypt # Transparent file encryption in git

    # ===== DevOps Tools =====
    (docker_29.override { clientOnly = true; }) # Docker CLI
    docker-compose # Docker orchestration

    # ===== Networking =====
    dnsutils # dig/delv — query the Pi DNS hosts from outside

    # ===== Formatters =====
    nixfmt-rfc-style # Nix formatter

    # ===== Misc Development =====
    gnumake # Make build tool
    gcc # C compiler (needed for some builds)
    direnv # Per-directory environment variables
  ];

  # Dev-specific shell aliases (merged with common aliases via module system)
  shell-common.aliases = {
    # Package manager
    pn = "pnpm";

    # AI tools
    cld = "claude";
  };

  # Dev-specific session variables
  home.sessionVariables = {
    # Point rust tooling at the Nix-provided stdlib source
    RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
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
