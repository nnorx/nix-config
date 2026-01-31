# Nix Configuration

A reproducible development environment managed with Nix Flakes and Home Manager.

## Prerequisites

- Linux (tested on Debian WSL and Raspberry Pi OS)
- [Nix package manager](https://nixos.org/) with flakes enabled

## Install Nix

If you haven't installed Nix yet:

```bash
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
exec $SHELL -l
```

Verify installation:
```bash
nix --version
```

## First-Time Setup

1. Clone this repository:
   ```bash
   git clone git@github.com:nnorx/nix-config.git ~/nix-config
   cd ~/nix-config
   ```

2. Apply the configuration:
   ```bash
   # On x86_64 Linux (including WSL)
   nix run home-manager -- switch --flake .#nick
   
   # On Raspberry Pi (aarch64)
   nix run home-manager -- switch --flake .#core5
   ```

3. Restart your shell:
   ```bash
   exec $SHELL -l
   ```

## Updating

After making changes to your configuration:

```bash
cd ~/nix-config
nix run home-manager -- switch --flake .#nick
```

To update all packages to latest versions:

```bash
cd ~/nix-config
nix flake update
nix run home-manager -- switch --flake .#nick
```

## Repository Structure

```
nix-config/
├── flake.nix          # Entry point - defines inputs and outputs
├── flake.lock         # Locked dependency versions
├── home/
│   ├── default.nix    # Main Home Manager config
│   ├── bash.nix       # Bash shell + Starship prompt
│   ├── git.nix        # Git configuration + aliases
│   ├── dev-tools.nix  # Development packages (Node, Rust, CLI tools)
│   ├── tmux.nix       # tmux terminal multiplexer
│   └── neovim.nix     # Neovim editor configuration
└── README.md
```

## What's Included

### Shell (bash.nix)
- Bash with useful aliases
- Starship prompt (shows git status, language versions, etc.)
- Better history search with arrow keys

### Git (git.nix)
- Pre-configured aliases (e.g., `git lg` for pretty log)
- Sensible defaults (rebase on pull, push current branch)
- GitHub CLI (`gh`)

### Development Tools (dev-tools.nix)
- **Node.js 22** with npm, pnpm, TypeScript
- **Rust** with cargo, rustfmt, clippy, rust-analyzer
- **CLI tools**: ripgrep, fd, jq, bat, fzf, htop
- **DevOps**: docker-compose, kubectl, k9s
- **direnv** for per-project environments

### tmux (tmux.nix)
- Prefix changed to `Ctrl+a`
- Vim-style pane navigation
- Mouse support
- Session persistence (survives restarts)

### Neovim (neovim.nix)
- Catppuccin theme
- Treesitter syntax highlighting
- Telescope fuzzy finder (`<leader>ff` to find files)
- LSP support for TypeScript, Rust, Nix
- File explorer with nvim-tree (`<leader>e`)
- Git signs in gutter

## Customization

### Change Git Identity

Edit `home/git.nix` and update:
```nix
userName = "Your Name";
userEmail = "your@email.com";
```

### Add New Packages

Edit `home/dev-tools.nix` and add packages to `home.packages`:
```nix
home.packages = with pkgs; [
  # ... existing packages ...
  your-new-package
];
```

Find packages at: https://search.nixos.org/packages

### Add Shell Aliases

Edit `home/bash.nix` and add to `shellAliases`:
```nix
shellAliases = {
  # ... existing aliases ...
  myalias = "my-command --with-flags";
};
```

## Troubleshooting

### WSL: Nix daemon not running

If you see "cannot connect to socket" errors after installing Nix in WSL:

```bash
# Start the Nix daemon manually
sudo /nix/var/nix/profiles/default/bin/nix-daemon &

# Or enable systemd in WSL (recommended)
# Add to /etc/wsl.conf:
# [boot]
# systemd=true
# Then restart WSL: wsl --shutdown
```

### Command not found after switch

Restart your shell or run:
```bash
exec $SHELL -l
```

### Flake not found

Make sure you're in the nix-config directory and it's a git repo:
```bash
cd ~/nix-config
git init
git add .
```

## Useful Commands

| Command | Description |
|---------|-------------|
| `nix run home-manager -- switch --flake .#nick` | Apply configuration |
| `nix flake update` | Update all inputs to latest |
| `nix flake show` | Show flake outputs |
| `nix search nixpkgs <package>` | Search for packages |
| `nix shell nixpkgs#<package>` | Temporarily use a package |
| `nix develop` | Enter development shell (if defined) |

## Learning Resources

- [Zero to Nix](https://zero-to-nix.com/) - Interactive tutorial
- [Nix Pills](https://nixos.org/guides/nix-pills/) - In-depth Nix language guide
- [Home Manager Options](https://nix-community.github.io/home-manager/options.xhtml) - All configuration options
- [NixOS Package Search](https://search.nixos.org/packages) - Find packages

---

Inspired by [clvx/nix-files](https://github.com/clvx/nix-files)
