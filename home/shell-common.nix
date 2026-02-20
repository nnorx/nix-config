# Shared shell configuration used by both bash.nix and zsh.nix
# Aliases and PATH setup shared across shells

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
    g = "git";
    gs = "git switch";
    gl = "git log --oneline -20";
    lg = "lazygit";
    
    # Nix shortcuts
    hms = "nix run home-manager -- switch --flake ~/projects/nix-config";
    nfu = "nix flake update";
    ngc = "nix-collect-garbage --delete-older-than 30d";
    
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

}
