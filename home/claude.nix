# Claude Code configuration.
#
# Plugin marketplaces are pinned as flake inputs, so each lands in the store as
# a plain source path. Declaring them here as "directory" sources means Claude
# Code registers them during startup with no imperative `claude plugin`
# commands on a new machine, and with no network access. Claude only ever reads
# a marketplace path, so a read-only store path is safe.
#
# Third-party skills are consumed upstream this way rather than vendored into
# nnorx/claude-plugins, so `nix flake update <input>` is the whole update path.
#
# Caveat: settings.json is a read-only store symlink, so /model and /config
# cannot write to it. Change the model here and re-switch instead.

{
  pkgs,
  lib,
  claudeMarketplaces,
  ...
}:
let
  settings = {
    model = "opus";
    effortLevel = "xhigh";
    switchModelsOnFlag = false;

    extraKnownMarketplaces = lib.mapAttrs (_name: src: {
      source = {
        source = "directory";
        path = "${src}";
      };
    }) claudeMarketplaces;

    # "<plugin>@<marketplace>". The marketplace half must match the `name`
    # field in that marketplace's .claude-plugin/marketplace.json, NOT the
    # attribute key above. A mismatch fails with a misleading
    # "Plugin not found".
    enabledPlugins = {
      "core@nnorx" = true;
      "improve@improve" = true;
    };
  };
in
{
  home.file.".claude/settings.json".source =
    (pkgs.formats.json { }).generate "claude-settings.json" settings;
}
