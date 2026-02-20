# Bash shell configuration

{ config, pkgs, ... }:
{
  programs.bash = {
    enable = true;

    # Use shared aliases from shell-common.nix
    shellAliases = config.shell-common.aliases;

    # Bash-specific history options
    historyControl = [
      "ignoredups"
      "erasedups"
      "ignorespace"
    ];
    historyFileSize = 10000;
    historySize = 10000;

    # Bash-specific configuration
    initExtra = ''
      ${config.shell-common.pathSetup}

      # Better history search with up/down arrows (bash syntax)
      bind '"\e[A": history-search-backward'
      bind '"\e[B": history-search-forward'

      # Case-insensitive tab completion
      bind 'set completion-ignore-case on'

      # Show all matches on ambiguous completion
      bind 'set show-all-if-ambiguous on'
    '';
  };
}
