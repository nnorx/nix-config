# tmux - terminal multiplexer configuration

{ pkgs, ... }:
{
  programs.tmux = {
    enable = true;

    # Use 256 colors
    terminal = "screen-256color";

    # Use Nix-managed zsh (fixes shell integrations in tmux on macOS)
    shell = "${pkgs.zsh}/bin/zsh";

    # Start window numbering at 1
    baseIndex = 1;

    # Faster escape time (important for vim)
    escapeTime = 10;

    # More history
    historyLimit = 50000;

    # Enable mouse support
    mouse = true;

    # Use vi keys in copy mode
    keyMode = "vi";

    # Prefix key (Ctrl+a instead of Ctrl+b)
    prefix = "C-a";

    plugins = with pkgs.tmuxPlugins; [
      sensible # Sensible defaults
      yank # Better copy/paste
      {
        plugin = resurrect; # Save/restore sessions
        extraConfig = "set -g @resurrect-strategy-nvim 'session'";
      }
      {
        plugin = continuum; # Auto-save sessions
        extraConfig = ''
          set -g @continuum-restore 'on'
          set -g @continuum-save-interval '10'
        '';
      }
    ];

    extraConfig = ''
      # Force interactive (non-login) shell so .zshrc is sourced in tmux
      set -g default-command "${pkgs.zsh}/bin/zsh"

      # Enable true color support
      set -ga terminal-overrides ",*256col*:Tc"

      # Reload config with prefix + r
      bind r source-file ~/.config/tmux/tmux.conf \; display "Config reloaded!"

      # Split panes with | and -
      bind | split-window -h -c "#{pane_current_path}"
      bind - split-window -v -c "#{pane_current_path}"
      unbind '"'
      unbind %

      # New window in current path
      bind c new-window -c "#{pane_current_path}"

      # Navigate panes with vim keys
      bind h select-pane -L
      bind j select-pane -D
      bind k select-pane -U
      bind l select-pane -R

      # Resize panes with vim keys (prefix + H/J/K/L)
      bind -r H resize-pane -L 5
      bind -r J resize-pane -D 5
      bind -r K resize-pane -U 5
      bind -r L resize-pane -R 5

      # Quick window switching
      bind -r p previous-window
      bind -r n next-window

      # Status bar styling
      set -g status-position bottom
      set -g status-style 'bg=#1e1e2e fg=#cdd6f4'
      set -g status-left '#[fg=#1e1e2e,bg=#89b4fa,bold] #S '
      set -g status-right '#[fg=#cdd6f4,bg=#313244] %Y-%m-%d %H:%M '
      set -g status-left-length 50
      set -g status-right-length 50

      # Window status styling
      set -g window-status-current-style 'fg=#1e1e2e bg=#a6e3a1 bold'
      set -g window-status-current-format ' #I:#W#F '
      set -g window-status-style 'fg=#cdd6f4 bg=#313244'
      set -g window-status-format ' #I:#W#F '

      # Pane border styling
      set -g pane-border-style 'fg=#313244'
      set -g pane-active-border-style 'fg=#89b4fa'

      # Copy mode vi bindings
      bind -T copy-mode-vi v send-keys -X begin-selection
      bind -T copy-mode-vi y send-keys -X copy-selection-and-cancel
      bind -T copy-mode-vi r send-keys -X rectangle-toggle
    '';
  };
}
