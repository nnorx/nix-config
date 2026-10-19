# SSH public keys for the `diag` login (modules/diag-login.nix), one per admin
# machine, the same model as ./ssh-keys.nix: each private half is generated on
# its machine and never leaves it.
#
# A separate key from id_ed25519_pis, because sshd tells logins apart by key:
# this one opens `diag`, which is outside wheel, and fleet-ssh offers it and
# nothing else. It has no passphrase, since fleet-ssh signs with the file
# rather than an agent. Every machine keeps it at ~/.ssh/id_ed25519_diag.
{
  wsl = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBKS4Sq8cyK63pHZPP4khnOrcAGSH7XIw5UAytQFI/i8 nick@wsl-diag";
  forge = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHQ9nc/CeY/AzIKlwiJTnwPlxOJXnbGgF3tPVfBd2sYO nick@forge-diag";
}
