# Starship prompt configuration (shared between shells)

{ ... }:
{
  programs.starship = {
    enable = true;

    settings = {
      format = "$directory$git_branch$git_status$nodejs$rust$python$nix_shell$cmd_duration$line_break$character";
      add_newline = false;

      directory = {
        truncation_length = 3;
        truncate_to_repo = true;
      };

      git_branch = {
        symbol = "git:";
        style = "bold purple";
      };

      git_status = {
        conflicted = "⚔️ ";
        ahead = "⬆️ ";
        behind = "⬇️ ";
        diverged = "↕️ ";
        untracked = "?";
        stashed = "📦 ";
        modified = "!";
        staged = "+";
        renamed = "»";
        deleted = "✘";
      };

      nodejs = {
        symbol = "node ";
        style = "bold green";
      };

      rust = {
        symbol = "rs ";
        style = "bold red";
      };

      python = {
        symbol = "py ";
        style = "bold yellow";
      };

      nix_shell = {
        symbol = "❄️ ";
        style = "bold blue";
      };

      cmd_duration = {
        min_time = 2000;
        format = "took [$duration]($style) ";
      };

      character = {
        success_symbol = "[>](bold green)";
        error_symbol = "[>](bold red)";
      };
    };
  };
}
