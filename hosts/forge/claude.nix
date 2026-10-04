# Claude Code's sandbox as managed settings.
#
# home/claude.nix writes the same policy to ~/.claude/settings.json, but that
# is one settings scope among several. A repository's .claude/settings.json or
# settings.local.json outranks it, so a trusted checkout can add
# excludedCommands, switch the sandbox off through /sandbox, or widen what
# commands may read. Managed settings outrank every scope, and with
# allowUnsandboxedCommands false the sandbox is admin-required: Claude Code
# then ignores a repository's loosening settings altogether, and the
# credentials deny here also blocks an allowRead carve-out beneath it. User
# settings still apply, which is where the allowed domains and fleet-ssh live.
#
# Only forge has a system layer in this flake. WSL runs Home Manager alone and
# stays at user level. The Mac has no sandbox (home/claude.nix).
#
# home/claude.nix opens every Unix socket on Linux, because nix needs its
# daemon and the sandbox cannot open just one there. Group membership then
# decides what else that reaches, which is why nick is not in `docker`
# (default.nix).
{ pkgs, lib, ... }:
let
  policy = import ../../lib/claude-sandbox.nix {
    inherit lib;
    isDarwin = pkgs.stdenv.isDarwin;
  };
  format = pkgs.formats.json { };
in
{
  environment.etc."claude-code/managed-settings.json".source =
    format.generate "claude-managed-settings.json"
      { sandbox = policy.strict; };
}
