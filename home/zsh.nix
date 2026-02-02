# Zsh shell configuration (macOS default shell)

{ config, pkgs, ... }:
{
  programs.zsh = {
    enable = true;
    
    # Use shared aliases from shell-common.nix
    shellAliases = config.shell-common.aliases;
    
    # Zsh-specific history settings
    history = {
      size = 10000;
      save = 10000;
      ignoreDups = true;
      ignoreSpace = true;
      extended = true;
      share = true;
    };
    
    # Zsh-specific features
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    
    # Zsh-specific configuration
    initExtra = ''
      ${config.shell-common.pathSetup}
      
      # Better history search with up/down arrows (zsh syntax)
      bindkey "^[[A" history-search-backward
      bindkey "^[[B" history-search-forward
      
      # Case-insensitive tab completion
      zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
    '';
  };

  # Enable starship zsh integration
  programs.starship.enableZshIntegration = true;
}
