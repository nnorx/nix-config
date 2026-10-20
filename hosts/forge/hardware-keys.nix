# Hardware security keys: PIV through pcscd, for age identities, and FIDO2,
# for SSH. docs/keys.md has what each key is for and the order of work; the
# identities and resident keys themselves are made by hand, not here.
#
# FIDO2 needs nothing from this file to reach a key. systemd's 60-fido-id.rules
# marks a hidraw node that speaks FIDO as a security token, and its
# 70-uaccess.rules gives the active seat's user access to it, which is how the
# browser already uses the keys for web logins. OpenSSH is built with libfido2
# and makes `ed25519-sk` keys as it is.
{ pkgs, ... }:
{
  # Also brings the CCID driver, whose udev rules hand smart card readers to
  # pcscd's group, and the socket at /run/pcscd. With polkit on, as Plasma has
  # it, the build is the polkit one, which lets the active session's user in.
  # Claude Code's sandbox denies that directory (lib/claude-sandbox.nix).
  services.pcscd.enable = true;

  environment.systemPackages = with pkgs; [
    # age and sops look for age-plugin-* on PATH when a recipient or identity
    # names the plugin.
    age-plugin-yubikey
    yubikey-manager # ykman, for the PIV and FIDO2 applications' settings
    libfido2 # fido2-token
  ];
}
