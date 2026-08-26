# Dev profile — full development environment
# Imports the common profile plus dev tools, languages, and LSPs
# Used by dev hosts (WSL, macOS)

{ ... }:
{
  imports = [
    ./common.nix # Common profile (shell, git, editor, basic CLI tools)
    ./dev-tools.nix # Dev tools (Node, Rust, Docker, kubectl, LSPs, etc.)
    ./ssh.nix # keychain-managed ssh-agent (dev hosts only)
    ./claude.nix # Claude Code settings + personal skills marketplace
  ];
}
