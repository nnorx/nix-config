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
# settings.json is written as a real file rather than linked from the store,
# because Claude Code rewrites the whole file itself: /model, /config and the
# plugin commands all do. Against a read-only store symlink those writes fail,
# which left editing this file and re-switching as the only way to change
# model. The merge below keeps the declarative half without costing that.
#
#   managed   Nix owns outright, rewritten on every switch. Marketplace paths
#             are store paths that move on `nix flake update`, and plugin
#             enablement is meant to be declarative, so a value that drifts
#             here is a bug rather than a preference.
#
#   defaults  Seeded only when the key is absent, so a fresh machine comes up
#             on opus/xhigh and afterwards /model owns the value.
#
# Everything else Claude Code stores here is carried through untouched.

{
  pkgs,
  lib,
  claudeMarketplaces,
  ...
}:
let
  managed = {
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

  defaults = {
    model = "opus";
    effortLevel = "xhigh";
    switchModelsOnFlag = false;
  };
in
{
  home.activation.claudeSettings = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    settings="$HOME/.claude/settings.json"
    mkdir -p "$HOME/.claude"

    # Earlier generations linked this path into the store. linkGeneration drops
    # that symlink when it is the one Home Manager wrote, but clear it here too
    # so a hand-made link cannot make the write below land in /nix/store.
    if [ -L "$settings" ]; then
      rm -f "$settings"
    fi

    # Anything unparseable is treated as absent rather than failing the switch,
    # which would otherwise leave the whole activation half-applied.
    existing='{}'
    if [ -f "$settings" ] && ${pkgs.jq}/bin/jq -e . "$settings" >/dev/null 2>&1; then
      existing="$(cat "$settings")"
    fi

    printf '%s' "$existing" | ${pkgs.jq}/bin/jq -S \
      --argjson defaults ${lib.escapeShellArg (builtins.toJSON defaults)} \
      --argjson managed ${lib.escapeShellArg (builtins.toJSON managed)} \
      '$defaults * del(.extraKnownMarketplaces, .enabledPlugins) * $managed' \
      > "$settings.next"
    mv "$settings.next" "$settings"
  '';
}
