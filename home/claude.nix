# Claude Code configuration.
#
# The personal skills marketplace (github:nnorx/claude-plugins) is pinned as a
# flake input, so it lands in the store as a plain source path. Declaring it
# here as a "directory" source means Claude Code registers it during startup
# with no imperative `claude plugin` commands on a new machine, and it never
# needs network access to do so. Claude only ever reads the marketplace path,
# so a read-only store path is safe.
#
# Caveat: settings.json is a read-only store symlink, so /model and /config
# cannot write to it. Change the model here and re-switch instead.

{
  pkgs,
  claudePlugins,
  ...
}:
let
  settings = {
    model = "opus";
    effortLevel = "xhigh";
    switchModelsOnFlag = false;

    extraKnownMarketplaces.nnorx.source = {
      source = "directory";
      path = "${claudePlugins}";
    };

    # The "nnorx" half must match the `name` field in the marketplace's
    # .claude-plugin/marketplace.json, NOT the attribute key above. A mismatch
    # fails with a misleading "Plugin not found".
    enabledPlugins."core@nnorx" = true;
  };
in
{
  home.file.".claude/settings.json".source =
    (pkgs.formats.json { }).generate "claude-settings.json" settings;
}
