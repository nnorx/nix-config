# Boot, Secure Boot, and hibernation.
{ lib, ... }:
let
  # Secure Boot is switched on in stages, and this is the switch. Order:
  #
  #   1. Install and first boot with systemd-boot (this false).
  #   2. `sudo sbctl create-keys`, which writes the keys to /var/lib/sbctl.
  #   3. Set this true and rebuild. Lanzaboote now signs what it installs;
  #      `sudo sbctl verify` should say so. If the keys are missing, the
  #      bootloader install fails, which is the guard against flipping this
  #      before step 2.
  #   4. Firmware into Setup Mode, `sbctl enroll-keys`, enforce Secure Boot.
  #      docs/laptop.md has the Framework-specific steps and flags.
  secureBoot = false;
in
{
  boot.loader.systemd-boot.enable = if secureBoot then lib.mkForce false else true;
  boot.lanzaboote = lib.mkIf secureBoot {
    enable = true;
    pkiBundle = "/var/lib/sbctl";
  };

  # Lets NixOS register itself in the firmware boot order. That matters again
  # once Windows is installed: its installer puts itself first.
  boot.loader.efi.canTouchEfiVariables = true;

  # The default is unbounded. Lanzaboote reads this same value.
  boot.loader.systemd-boot.configurationLimit = 10;

  # systemd in the initrd: a better passphrase prompt, and the path to TPM2
  # unlocking later. It is also what makes hibernation to a swapfile simple:
  # systemd records the image location in the HibernateLocation EFI variable
  # when it hibernates, and the initrd resumes from it, so there is no
  # resume_offset to compute and keep in sync with the file.
  boot.initrd.systemd.enable = true;

  # Everyday swap in compressed RAM. It has a higher priority than the swapfile
  # from disko.nix, so the disk is written when hibernating and almost never
  # otherwise.
  zramSwap.enable = true;

  # The FW16 on AMD has only s2idle sleep, and the dGPU module adds to its
  # drain, so a closed lid suspends and then, after two hours, hibernates.
  services.logind.settings.Login.HandleLidSwitch = "suspend-then-hibernate";
  systemd.sleep.settings.Sleep.HibernateDelaySec = "2h";
}
