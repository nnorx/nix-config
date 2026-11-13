# Boot images, each with the fleet's SSH key for headless access. Build one
# with `nix build .#packages.<system>.<name> --accept-flake-config`.
{
  nixpkgs,
  nixos-raspberrypi,
  sshPubKeys,
}:
let
  # Host-agnostic: every Pi 3/4 gets the same image, and its host config is
  # applied by nixos-rebuild after first boot.
  piInstaller =
    (nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
        (
          { lib, ... }:
          {
            services.openssh.enable = true;
            security.sudo.wheelNeedsPassword = false;
            users.users.nixos = {
              isNormalUser = true;
              extraGroups = [ "wheel" ];
              openssh.authorizedKeys.keys = sshPubKeys;
            };
            # Disable ZFS — not used on Pis, and its services hang during nixos-rebuild switch
            boot.supportedFilesystems.zfs = lib.mkForce false;
          }
        )
      ];
    }).config.system.build.sdImage;
in
{
  aarch64-linux = {
    core4-installer = piInstaller;
    lifeline-installer = piInstaller;

    # The Pi 5 needs nixos-raspberrypi's own installer.
    core5-installer =
      (nixos-raspberrypi.lib.nixosInstaller {
        specialArgs = {
          inherit nixos-raspberrypi;
        };
        modules = [
          (
            { nixos-raspberrypi, ... }:
            {
              imports = with nixos-raspberrypi.nixosModules; [
                raspberry-pi-5.base
                raspberry-pi-5.page-size-16k
              ];
            }
          )
          {
            users.users.nixos.openssh.authorizedKeys.keys = sshPubKeys;
          }
        ];
      }).config.system.build.sdImage;
  };

  # Headless x86 recovery ISO. The stock NixOS minimal image assumes a monitor
  # and keyboard; this one boots on DHCP with sshd and the fleet key, so a box
  # that will not boot its own generations is still reachable over the
  # network. Recovery is then `nixos-enter` against the mounted root, or
  # picking an older generation with `bootctl`.
  x86_64-linux.recovery-iso =
    (nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
        (
          { lib, pkgs, ... }:
          {
            # A reinstall makes the host's Secure Boot keys here, before its
            # own system exists to run sbctl.
            environment.systemPackages = [ pkgs.sbctl ];

            # No host in this fleet uses ZFS, and on a rescue image the
            # default is actively wrong: boot.zfs.forceImportRoot defaults to
            # true, which imports a pool even when another system has it
            # marked in use. Booting rescue against a live pool is how one
            # gets corrupted. Dropping ZFS removes the hazard rather than
            # muting the warning, as the Pi installer does.
            boot.supportedFilesystems.zfs = lib.mkForce false;
          }
        )
        {
          # The live environment's only account is root and it has no
          # password, so the key is the sole way in. The installer profile
          # already enables sshd with PermitRootLogin, but leaves
          # PasswordAuthentication on, which only fails closed because sshd's
          # own PermitEmptyPasswords default is "no". Say it explicitly rather
          # than resting on that.
          services.openssh.settings.PasswordAuthentication = false;
          users.users.root.openssh.authorizedKeys.keys = sshPubKeys;
        }
      ];
    }).config.system.build.isoImage;
}
