# Nix Configuration

Reproducible system and development configuration managed with Nix Flakes — covering NixOS on a Raspberry Pi fleet and an x86 router, Home Manager for dev environments, and shared modules for DNS, firewalls, and security.

## Network Architecture

```
                          LAN clients
                    /                     \
                   v                       v
┌──────────────────────┐      ┌──────────────────────┐
│  core4 (Pi 4)        │      │  lifeline (Pi 4)     │
│                      │      │                      │
│  AdGuard Home (:53)  │      │  AdGuard Home (:53)  │
│  - Ad/tracker block  │      │  - Ad/tracker block  │
│         |            │      │         |            │
│         v            │      │         v            │
│  Unbound (127.0.0.1) │      │  Unbound (127.0.0.1) │
│  - Recursive resolver│      │  - Recursive resolver│
│  - DNS caching       │      │  - DNS caching       │
│  - DNSSEC validation │      │  - DNSSEC validation │
│                      │      │                      │
│  Fallback:           │      │  Fallback:           │
│  1.1.1.1 / 8.8.8.8   │      │  1.1.1.1 / 8.8.8.8   │
│                      │      │                      │
│  Web UI :3000        │      │  Web UI :3000        │
│  Docker              │      └──────────────────────┘
└──────────────────────┘
┌──────────────────────┐
│  core5 (Pi 5)        │
│  pimon collector     │
│  Docker              │
└──────────────────────┘
```

**DNS flow:** core4 and lifeline are each self-contained. AdGuard Home filters on `:53` and forwards to that same host's Unbound, which listens on loopback only and resolves recursively from the root servers with DNSSEC. They share no state and neither depends on the other, so either can serve the LAN alone.

The router is configured with both as upstreams and proxies client DNS to them, so queries reach AdGuard from the gateway address rather than from individual clients.

### Hosts

| Host | Hardware | Role |
|------|----------|------|
| **core4** | Raspberry Pi 4 (8GB) | AdGuard Home + Unbound recursive resolver + Docker |
| **lifeline** | Raspberry Pi 4 | AdGuard Home + Unbound recursive resolver — independent second DNS path |
| **core5** | Raspberry Pi 5 | pimon collector, Docker, general purpose |
| **gate** | CWWK N100 (4x Intel i226) | The future router. Under config, not routing yet — see [docs/router.md](docs/router.md) |

Addressing (static IPs, interface names, cross-host ports) lives in `lib/net.nix` and is threaded to every host through `specialArgs`. Nothing else in the tree hardcodes an address, so renumbering the LAN is a one-file change.

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

## NixOS Deployment

### Rebuilding a host

From the Pi itself (or over SSH):

```bash
sudo nixos-rebuild switch --flake github:nnorx/nix-config#core4 --accept-flake-config --refresh
```

Replace `core4` with the target hostname (`core4`, `core5`, `lifeline`, `gate`).

`gate` is not a Pi, and its first deploy from a fresh install differs: the
attribute has to be named explicitly, because `nixos-rebuild` otherwise resolves
it from a hostname that is not yet `gate`. Use `boot` and a reboot rather than
`switch`, since the rebuild reconfigures the interface the session runs over.
See [docs/router.md](docs/router.md).

If the Pi resolves DNS through itself and can't reach GitHub, temporarily override DNS first:

```bash
sudo bash -c 'echo "nameserver 1.1.1.1" > /etc/resolv.conf'
```

### First-time setup (flashing a new Pi)

The installer image is **host-agnostic** — `core4-installer`, `core5-installer` and `lifeline-installer` are the same derivation. It boots as user `nixos` on DHCP with the fleet SSH key; the host identity is applied by `nixos-rebuild` afterwards.

1. Build the image (any machine with Nix, e.g. WSL):
   ```bash
   nix build .#packages.aarch64-linux.lifeline-installer --accept-flake-config
   ```
   The output is **zstd-compressed** — `result/sd-image/*.img.zst`, about 1.3 GiB compressed and 3.1 GiB expanded.

2. Flash it. **Do not `dd` from WSL.** WSL2 cannot see USB card readers, and `/dev/sda`–`/dev/sdd` there are WSL's own virtual disks — one of which is its root filesystem. Flash from whichever OS owns the reader.

   **From Windows** — decompress somewhere Windows can read, then use Raspberry Pi Imager or balenaEtcher ("Use custom" → pick the image):
   ```bash
   nix run nixpkgs#zstd -- -d result/sd-image/*.img.zst -o /mnt/c/Users/<you>/nixos-sd.img
   ```
   Current Raspberry Pi Imager reads `.img.zst` directly if you would rather skip the decompress step.

   **From a Linux host with the reader attached** — confirm the device with `lsblk` first, since `dd` asks nothing and cannot be undone:
   ```bash
   zstd -d result/sd-image/*.img.zst -o nixos-sd.img
   sudo dd if=nixos-sd.img of=/dev/sdX bs=4M status=progress conv=fsync
   ```

   Use 16 GB or larger. The image is ~3 GiB and NixOS expands the root partition on first boot, but `nix.gc` keeps 14 days of generations and a rebuild needs room for the old and new one simultaneously.

3. Boot the Pi and find its DHCP address (the router's device list, or a ping sweep). Pass the key explicitly — a bare IP matches no `Host` block in `~/.ssh/config`:
   ```bash
   ssh -i ~/.ssh/id_ed25519_pis nixos@<dhcp-address>
   ```
   Do not go looking for a password: the `nixos` account has none, so the key is the only way in.

4. Low-RAM boards only (1 GB Pi 3B and similar) — add temporary swap:
   ```bash
   sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
   ```

5. Build, stage, reboot. **Run these one at a time.** Pasted as a block, interrupting one leaves the shell to run the rest — including the reboot:
   ```bash
   sudo bash -c 'echo "nameserver 1.1.1.1" > /etc/resolv.conf'
   sudo nixos-rebuild build --flake github:nnorx/nix-config#lifeline --accept-flake-config --refresh
   sudo nixos-rebuild boot  --flake github:nnorx/nix-config#lifeline --accept-flake-config --refresh
   sudo reboot
   ```
   `boot` rather than `switch`: activation moves the host onto its static address from `lib/net.nix`, reconfiguring the very interface you are connected over. `boot` stages the generation and the reboot brings it up cleanly, and a failed boot leaves the previous generation selectable.

6. Reconnect at the static address and set a password:
   ```bash
   ssh <hostname>@<static-ip>   # address from lib/net.nix
   passwd                       # initialPassword is "changeme"
   ```
   SSH is key-only, so that password is only used for `sudo` and at the console.

### Recovery USB (x86 hosts)

`gate` is the one host that cannot be recovered by pulling a card and reflashing
it, so it gets a rescue image. It is the stock NixOS minimal ISO plus the fleet
SSH key, which makes it **headless**: it boots on DHCP with sshd running, so a
box that will not boot its own generations is still reachable over the network
rather than needing a monitor and keyboard at the rack.

1. Build it (any machine with Nix, e.g. WSL):
   ```bash
   nix build .#packages.x86_64-linux.recovery-iso --accept-flake-config
   ```
   The output is `result/iso/*.iso`, 1.4 GiB. Any USB stick will do.

2. Write it to a USB stick. **Do not `dd` from WSL** — the same warning as the
   Pi images above: `/dev/sda`-`/dev/sdd` there are WSL's own virtual disks.
   ```bash
   cp result/iso/*.iso /mnt/c/Users/<you>/nixos-recovery.iso
   ```
   Then Rufus or balenaEtcher on the Windows side. From a Linux host with the
   stick attached, confirm the device with `lsblk` first:
   ```bash
   sudo dd if=result/iso/*.iso of=/dev/sdX bs=4M status=progress conv=fsync
   ```

3. Test it once, while nothing depends on the box. Plug it in, reboot, and try
   to SSH to the new DHCP address as root:
   ```bash
   ssh -i ~/.ssh/id_ed25519_pis root@<dhcp-address>
   ```
   Two outcomes, both useful. If you get a shell, headless recovery works and
   the monitor stays in the cupboard. If the host comes back as itself instead,
   USB is behind the internal disk in the boot order, and that is the one thing
   worth a single visit with a monitor to change in the firmware.

4. To recover a broken host from it:
   ```bash
   mount /dev/nvme0n1p2 /mnt && mount /dev/nvme0n1p1 /mnt/boot
   nixos-enter --root /mnt
   # then, inside:
   nix-env --list-generations --profile /nix/var/nix/profiles/system
   /nix/var/nix/profiles/system-<N>-link/bin/switch-to-configuration boot
   ```
   Reboot without the stick. Device names are from `hosts/gate/hardware-configuration.nix`.

## Repository Structure

```
nix-config/
├── flake.nix              # Entry point - defines inputs, outputs, installer images, and NixOS configs
├── flake.lock             # Locked dependency versions
├── lib/
│   └── net.nix            # LAN topology — static IPs, interface names, cross-host ports
├── hosts/
│   ├── common/            # Fleet-wide NixOS config (locale, user accounts, baseline)
│   │   └── pi.nix         # Pi-only boot and SD-card storage layout
│   ├── core4/             # Pi 4 — AdGuard Home + Unbound + Docker
│   ├── core5/             # Pi 5 — pimon collector, Docker
│   ├── lifeline/          # Pi 4 — AdGuard Home + Unbound, independent DNS path
│   └── gate/              # CWWK N100 — the router, not routing yet
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
│   ├── security.nix       # vulnix CVE scanner + whitelist wiring
│   ├── vulnix-whitelist.toml # Suppressed false positives (Haskell name collisions, bootstrap-only)
│   ├── dev-tools.nix      # Dev-only packages (Node, Rust, Docker, LSPs)
│   ├── shell-common.nix   # Shared aliases and PATH setup for bash/zsh
│   ├── starship.nix       # Starship prompt configuration
│   ├── bash.nix           # Bash-specific shell configuration
│   ├── zsh.nix            # Zsh-specific shell configuration
│   ├── git.nix            # Git configuration + aliases + GitHub CLI
│   ├── tmux.nix           # tmux terminal multiplexer
│   ├── neovim.nix         # Neovim editor configuration
│   └── darwin.nix         # macOS-specific configuration
├── docs/
│   └── router.md          # Phased build plan for gate
└── README.md
```

### Profiles

| Profile | Hosts | What's included |
|---------|-------|-----------------|
| **Dev** (`default.nix`) | WSL (`nick`), macOS (`nicknorcross`) | Common + Node, Rust, Docker, kubectl, LSPs, direnv |
| **Common** (`common.nix`) | Pi 5 (`core5`), Pi 4 (`core4`, `lifeline`), N100 (`gate`) | Shell, git, CLI tools, tmux, neovim |
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

#### Security (security.nix)
- **vulnix** — scans the Nix store against the NVD CVE feed
- Shared whitelist (`vulnix-whitelist.toml`) suppresses known false positives: Haskell library name collisions (e.g. Haskell `vault` ≠ HashiCorp Vault), bootstrap-only build inputs, and specific NVD misattributions
- Aliases: `vulnix-scan` (home-manager closure), `vulnix-scan-system` (NixOS hosts)

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
- **Node.js 24** with npm, pnpm, TypeScript
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
| `vulnix-scan` | Scan active home-manager closure for CVEs |
| `vulnix-scan-system` | Scan the running NixOS system for CVEs (Pi hosts) |
| `nix flake show` | Show flake outputs |
| `nix search nixpkgs <package>` | Search for packages |
| `nix shell nixpkgs#<package>` | Temporarily use a package |
| `nix develop` | Enter development shell (if defined) |

### NixOS

| Command | Description |
|---------|-------------|
| `sudo nixos-rebuild switch --flake github:nnorx/nix-config#<host>` | Deploy config to a host |
| `sudo nixos-rebuild boot --flake github:nnorx/nix-config#<host>` | Stage for next boot, for changes that reconfigure the live interface |
| `nix build .#packages.aarch64-linux.<host>-installer` | Build installer SD image (Pis only) |
| `nix build .#packages.x86_64-linux.recovery-iso` | Build the headless x86 rescue ISO |
| `nix flake check --no-build` | Validate flake without building |

## Learning Resources

- [Zero to Nix](https://zero-to-nix.com/) - Interactive tutorial
- [Nix Pills](https://nixos.org/guides/nix-pills/) - In-depth Nix language guide
- [Home Manager Options](https://nix-community.github.io/home-manager/options.xhtml) - All configuration options
- [NixOS Package Search](https://search.nixos.org/packages) - Find packages

---

Inspired by [clvx/nix-files](https://github.com/clvx/nix-files)
