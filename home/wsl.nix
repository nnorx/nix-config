# WSL only, through homeConfigurations.nick in flake.nix.
{
  # WSL's own Unix sockets, which every sandboxed command can reach because
  # the sandbox opens them all on Linux (home/claude.nix). Each runs commands
  # outside the sandbox:
  #
  #   /run/WSL    Windows interop. `cmd.exe` from a command is a Windows
  #               process, which reads the distro through \\wsl.localhost,
  #               and `wsl.exe` starts a Linux process outside the sandbox.
  #   /mnt/wsl    shared between distros. Docker Desktop's socket lives here,
  #               and a container can mount the home directory, key included.
  #               forge leaves the docker group for the same reason.
  #   /mnt/wslg   WSLg's Wayland, X11 and audio. /tmp/.X11-unix, hidden in
  #               lib/claude-sandbox.nix, only links here.
  #
  # Hidden from commands only. The terminal, VS Code and Claude Code itself
  # keep interop, Docker and WSLg. The Windows drives under /mnt/c stay
  # readable: they hold no key, and with interop gone they are only files.
  claude-sandbox.extraDenyRead = [
    "/run/WSL"
    "/mnt/wsl"
    "/mnt/wslg"
  ];
}
