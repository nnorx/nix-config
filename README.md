# Nix Configuration

Reproducible system and development configuration managed with Nix Flakes — covering NixOS on a Raspberry Pi fleet, Home Manager for dev environments, and shared modules for DNS, firewalls, and security.

## Network Architecture

```
                     LAN clients
                    /           \
                   v             v
┌──────────────────────┐      ┌──────────────────────┐
│  core3 (Pi 3B)       │      │  core4 (Pi 4)        │
│  192.168.86.36       │      │  192.168.86.32       │
│                      │      │                      │
│  AdGuard Home (:53)  │──┐   │  AdGuard Home (:53)  │
│  - Ad/tracker block  │  │   │  - Ad/tracker block  │
│  - DNS caching       │  │   │                      │
│  - DNSSEC validation │  └──>│  Unbound (:5335)     │
│                      │      │  - Recursive resolver│
│  Fallback:           │      │  - DNS caching       │
│  1.1.1.1 / 8.8.8.8   │      │  - DNSSEC validation │
│                      │      │                      │
│  Web UI :3000        │      │  Fallback:           │
└──────────────────────┘      │  1.1.1.1 / 8.8.8.8   │
                              │                      │
┌──────────────────────┐      │  Web UI :3000        │
│  core5 (Pi 5)        │      │  Docker              │
│  192.168.86.35       │      └──────────────────────┘
│  (general purpose)   │
└──────────────────────┘
```

**DNS flow:** LAN clients → core3 AGH (filtering + cache) → core4 Unbound (recursive resolution to root servers with DNSSEC). Core4's own clients go through core4 AGH → core4 Unbound.

### Hosts

| Host | Hardware | IP | Role |
|------|----------|----|------|
| **core3** | Raspberry Pi 3B (1GB RAM) | 192.168.86.36 | AdGuard Home DNS (forwards to core4's Unbound) |
| **core4** | Raspberry Pi 4 (Argon ONE M.2 case) | 192.168.86.32 | AdGuard Home DNS + Unbound recursive resolver + Docker |
| **core5** | Raspberry Pi 5 | 192.168.86.35 | General purpose |

## Prerequisites

- Linux (tested on Debian WSL and Raspberry Pi OS) or macOS (Apple Silicon)
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
   git clone https://github.com/nnorx/nix-config.git ~/projects/nix-config
   cd ~/projects/nix-config
   ```

2. Apply the configuration:
   ```bash
   nix run home-manager -- switch --flake .
   ```
   
   This detects the right configuration based on your username.

3. Restart your shell:
   ```bash
   exec $SHELL -l
   ```

## Updating

After making changes to your configuration:

```bash
hms
```

To update all packages to latest versions:

```bash
cd ~/projects/nix-config
nfu && hms
```

## NixOS Deployment (Raspberry Pis)

### Rebuilding a host

From the Pi itself (or over SSH):

```bash
sudo nixos-rebuild switch --flake github:nnorx/nix-config#core4 --accept-flake-config --refresh
```

Replace `core4` with the target hostname (`core3`, `core4`, `core5`).

If the Pi resolves DNS through itself and can't reach GitHub, temporarily override DNS first:

```bash
sudo bash -c 'echo "nameserver 1.1.1.1" > /etc/resolv.conf'
```

### First-time setup (flashing a new Pi)

1. Build the installer image (from a machine with Nix — e.g., WSL):
   ```bash
   nix build .#packages.aarch64-linux.core3-installer --accept-flake-config
   ```

2. Flash to SD card:
   ```bash
   sudo dd if=result/sd-image/*.img of=/dev/sdX bs=4M status=progress
   ```

3. Boot the Pi, then SSH in:
   ```bash
   ssh nixos@<ip-address>
   ```

4. Set up temporary swap (important for low-RAM Pis like the 3B):
   ```bash
   sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
   ```

5. Build first, then switch (two-step avoids hanging during service stop):
   ```bash
   sudo bash -c 'echo "nameserver 1.1.1.1" > /etc/resolv.conf'
   sudo nixos-rebuild build --flake github:nnorx/nix-config#core3 --accept-flake-config --refresh
   sudo nixos-rebuild switch --flake github:nnorx/nix-config#core3 --accept-flake-config --refresh
   ```

6. After reboot, SSH in as the host user and change the default password:
   ```bash
   ssh core3@192.168.86.36
   passwd
   ```

## Repository Structure

```
nix-config/
├── flake.nix              # Entry point - defines inputs, outputs, installer images, and NixOS configs
├── flake.lock             # Locked dependency versions
├── hosts/
│   ├── common/            # Shared NixOS config for all Pis (boot, locale, user accounts)
│   ├── core3/             # Pi 3B — AdGuard Home DNS (forwards to core4)
│   ├── core4/             # Pi 4 — AdGuard Home + Unbound + Docker
│   └── core5/             # Pi 5 — general purpose
├── modules/
│   ├── adguardhome.nix    # Parameterized AGH module (upstream/fallback DNS, caching, DNSSEC)
│   ├── unbound.nix        # Recursive DNS resolver with DNSSEC
│   ├── docker.nix         # Docker daemon
│   ├── ssh.nix            # SSH server hardening (key-only, modern crypto)
│   ├── firewall.nix       # Default-deny firewall (SSH always allowed)
│   ├── fail2ban.nix       # Brute-force protection
│   └── baseline.nix       # Nix settings (flakes, substituters)
├── home/
│   ├── default.nix        # Dev profile entry point (imports common + dev-tools)
│   ├── common.nix         # Common profile entry point (shell, editor, CLI tools)
│   ├── common-tools.nix   # CLI essentials (ripgrep, fd, bat, fzf, etc.)
│   ├── dev-tools.nix      # Dev-only packages (Node, Rust, Docker, LSPs)
│   ├── shell-common.nix   # Shared aliases and PATH setup for bash/zsh
│   ├── starship.nix       # Starship prompt configuration
│   ├── bash.nix           # Bash-specific shell configuration
│   ├── zsh.nix            # Zsh-specific shell configuration
│   ├── git.nix            # Git configuration + aliases + GitHub CLI
│   ├── tmux.nix           # tmux terminal multiplexer
│   ├── neovim.nix         # Neovim editor configuration
│   └── darwin.nix         # macOS-specific configuration
└── README.md
```

### Profiles

| Profile | Hosts | What's included |
|---------|-------|-----------------|
| **Dev** (`default.nix`) | WSL (`nick`), macOS (`nicknorcross`) | Common + Node, Rust, Docker, kubectl, LSPs, direnv |
| **Common** (`common.nix`) | Pi 5 (`core5`), Pi 4 (`core4`), Pi 3B (`core3`) | Shell, git, CLI tools, tmux, neovim |
| **Darwin** (`darwin.nix`) | macOS only | GNU coreutils |

## What's Included

### Common Profile (all hosts)

#### Shell (shell-common.nix, bash.nix, zsh.nix, starship.nix)
- Bash and Zsh with shared aliases and PATH setup
- Starship prompt (shows git status, language versions, etc.)
- Better history search with arrow keys
- Zsh autosuggestions and syntax highlighting

#### Git (git.nix)
- Pre-configured aliases (e.g., `git lg` for pretty log)
- Sensible defaults (rebase on pull, push current branch)
- GitHub CLI (`gh`)

#### CLI Tools (common-tools.nix)
- **Search**: ripgrep, fd, fzf
- **Viewing**: bat, eza, tree, jq, yq
- **System**: htop, ncdu, curl, wget, unzip, tldr
- **Navigation**: zoxide (smarter cd)

#### tmux (tmux.nix)
- Prefix changed to `Ctrl+a`
- Vim-style pane navigation
- Mouse support
- Session persistence (survives restarts)

#### Neovim (neovim.nix)
- Catppuccin theme
- Treesitter syntax highlighting
- Telescope fuzzy finder with native FZF sorter (`<leader>ff` to find files)
- LSP support for TypeScript, Rust, Nix
- Autocompletion with nvim-cmp and snippet support (luasnip)
- File explorer with nvim-tree (`<leader>e`)
- Git signs in gutter with keybindings (`<leader>g`)

### Dev Profile (WSL, macOS only)

#### Development Tools (dev-tools.nix)
- **Node.js 22** with npm, pnpm, TypeScript
- **Rust** with cargo, rustfmt, clippy, rust-analyzer
- **DevOps**: docker-compose, kubectl, k9s
- **LSPs**: nil (Nix), typescript-language-server, rust-analyzer
- **Build**: gnumake, gcc
- **direnv** for per-project environments

## Dev Shells

The flake provides reusable dev shells for project-specific tooling via `nix develop` or direnv.

### Playwright E2E Testing

Provides Chromium with Nix-patched binaries — no system-level browser installs needed. Works across Debian, WSL, and other Linux environments.

**Per-project setup:**

1. Add an `.envrc` to your project:
   ```bash
   echo 'use flake ~/projects/nix-config#playwright' > .envrc
   direnv allow
   ```

2. Pin the matching `@playwright/test` version shown in the shell output:
   ```bash
   pnpm add -D @playwright/test@<version>
   ```

3. Run tests:
   ```bash
   pwt          # npx playwright test
   pwth         # --headed
   pwtd         # --debug
   pwui         # --ui mode
   pwshow       # show report
   pwgen        # codegen
   ```

**Or enter the shell directly:**
```bash
nix develop ~/projects/nix-config#playwright
```

## Customization

### Change Git Identity

Edit `home/git.nix` and update:
```nix
userName = "Your Name";
userEmail = "your@email.com";
```

### Add New Packages

Add to `home/common-tools.nix` for all hosts, or `home/dev-tools.nix` for dev hosts only:
```nix
home.packages = with pkgs; [
  # ... existing packages ...
  your-new-package
];
```

Find packages at: https://search.nixos.org/packages

### Add Shell Aliases

Edit `home/shell-common.nix` for common aliases, or `home/dev-tools.nix` for dev-only aliases:
```nix
shell-common.aliases = {
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
cd ~/projects/nix-config
git init
git add .
```

## Useful Commands

### Home Manager (dev environments)

| Command | Description |
|---------|-------------|
| `hms` | Apply configuration (alias for home-manager switch) |
| `nfu` | Update flake inputs (`nix flake update`) |
| `ngc` | Garbage collect Nix store (30+ days old) |
| `nix flake show` | Show flake outputs |
| `nix search nixpkgs <package>` | Search for packages |
| `nix shell nixpkgs#<package>` | Temporarily use a package |
| `nix develop` | Enter development shell (if defined) |

### NixOS (Raspberry Pis)

| Command | Description |
|---------|-------------|
| `sudo nixos-rebuild switch --flake github:nnorx/nix-config#<host>` | Deploy config to a Pi |
| `nix build .#packages.aarch64-linux.<host>-installer` | Build installer SD image |
| `nix flake check --no-build` | Validate flake without building |

## Learning Resources

- [Zero to Nix](https://zero-to-nix.com/) - Interactive tutorial
- [Nix Pills](https://nixos.org/guides/nix-pills/) - In-depth Nix language guide
- [Home Manager Options](https://nix-community.github.io/home-manager/options.xhtml) - All configuration options
- [NixOS Package Search](https://search.nixos.org/packages) - Find packages

---

Inspired by [clvx/nix-files](https://github.com/clvx/nix-files)
