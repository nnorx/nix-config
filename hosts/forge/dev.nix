# Desktop development: VS Code and what it needs to work on NixOS.
#
# Only VS Code itself is installed here. Its settings and extensions come from
# Settings Sync rather than Home Manager's programs.vscode, which would make
# settings.json a read-only store link that the editor cannot write to.
{ unstable, ... }:
{
  # From unstable: VS Code ships monthly and extensions declare a minimum
  # engine version, so the stable channel's build can be too old to install
  # current extensions.
  #
  # The password store is named because Electron's own detection fails under
  # Plasma 6: it reports that no OS keyring is available while KWallet 6 is
  # running, and Settings Sync then cannot store its sign-in. The flag goes in
  # the launcher, so the app menu entry gets it too.
  environment.systemPackages = [
    (unstable.vscode.override { commandLineArgs = "--password-store=kwallet6"; })
  ];

  # Extensions such as rust-analyzer download prebuilt Linux binaries, which
  # expect a dynamic loader at /lib64 that NixOS does not have, and fail with
  # "No such file or directory". nix-ld provides one. It covers the same
  # failure outside the editor too, for npm packages and Playwright browsers.
  programs.nix-ld.enable = true;

  # Makes the nixpkgs Electron wrappers, VS Code's included, run natively on
  # Wayland rather than through XWayland, which blurs at fractional scaling.
  environment.sessionVariables.NIXOS_OZONE_WL = "1";
}
