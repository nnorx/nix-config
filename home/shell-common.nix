# Shared shell configuration used by both bash.nix and zsh.nix
# Aliases and PATH setup shared across shells
# Dev-specific aliases live in dev-tools.nix and merge via the module system

{ pkgs, lib, ... }:
let
  # Helper to prepend to PATH only if not already present
  #   Usage: path_prepend "/some/dir"
  pathGuard = ''
    path_prepend() {
      case ":$PATH:" in
        *:"$1":*) ;;
        *) export PATH="$1:$PATH" ;;
      esac
    }
  '';

  # Common PATH setup (POSIX-compatible, works in both bash and zsh)
  commonPathSetup = ''
    ${pathGuard}

    # Ensure Nix profiles are in PATH
    path_prepend "/nix/var/nix/profiles/default/bin"
    path_prepend "$HOME/.nix-profile/bin"

    # Add local bin to PATH if it exists
    if [ -d "$HOME/.local/bin" ]; then
      path_prepend "$HOME/.local/bin"
    fi

    # Node.js global packages - use ~/.npm-global instead of read-only Nix store
    export NPM_CONFIG_PREFIX="$HOME/.npm-global"
    path_prepend "$HOME/.npm-global/bin"

    # Cargo/Rust path
    if [ -d "$HOME/.cargo/bin" ]; then
      path_prepend "$HOME/.cargo/bin"
    fi
  '';
in
{
  # Export these as module options so other files can use them
  options.shell-common = {
    aliases = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Common shell aliases shared between bash and zsh";
    };

    pathSetup = lib.mkOption {
      type = lib.types.str;
      default = commonPathSetup;
      description = "Common PATH setup script";
    };
  };

  # Set common aliases via config so dev-tools.nix can merge additional aliases
  config.shell-common.aliases = {
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

    # Nix shortcuts
    hms = "nix run home-manager -- switch --flake ~/projects/nix-config";
    nfu = "nix flake update";
    nff = "nix fmt -- **/*.nix";
    ngc = "nix-collect-garbage --delete-older-than 30d";

    # Interactive git
    gsb = "git branch | fzf | xargs git switch";
    gsr = "git branch --sort=-committerdate | fzf | xargs git switch";

    # Interactive file utilities
    fopen = "fd -t f | fzf --preview 'bat --color=always {}' | xargs nvim";
    bigfiles = "fd -t f -x du -h {} | sort -rh | head -20";

    # Misc
    c = "clear";
    h = "history";
  };
}
