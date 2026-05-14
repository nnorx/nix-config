# CVE scanning tooling.
#
# `vulnix` matches every Nix store path against the NVD CVE feed and prints
# a report. It produces many false positives because it matches on
# (pname, version) without knowing what ecosystem a package belongs to —
# the whitelist in this directory suppresses the known FPs.
#
# Usage:
#   vulnix-scan           # scan the active home-manager closure (HM-only hosts)
#   vulnix-scan-system    # scan the running NixOS system (Pi hosts only)
#   vulnix -w <whitelist> <path>   # scan an arbitrary path

{ pkgs, ... }:
{
  home.packages = [ pkgs.vulnix ];

  xdg.configFile."vulnix/whitelist.toml".source = ./vulnix-whitelist.toml;

  shell-common.aliases = {
    vulnix-scan = "vulnix -w ~/.config/vulnix/whitelist.toml $(readlink -f ~/.local/state/nix/profiles/home-manager)";
    vulnix-scan-system = "vulnix -w ~/.config/vulnix/whitelist.toml --system";
  };
}
