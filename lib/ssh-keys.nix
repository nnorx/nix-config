# SSH public keys allowed into the fleet, one per admin machine. Each private
# half is generated on its machine and never leaves it, so retiring or losing a
# machine means deleting its line here, without re-keying the others.
#
# Every machine keeps its key at ~/.ssh/id_ed25519_pis, the name home/ssh.nix
# and the runbooks use, so only the contents differ.
#
# wsl's key predates this file, when it was the one key every machine would
# have shared. Its comment still says nick@nix-config.
{
  wsl = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEF1Tvp3mQjByFOSRh4uXWZhRkquB3n5oNoLspunq+OV nick@nix-config";
  forge = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBHLsmtuQEznk32cltlRuWC9xto9wrsjzZzDoWGJCiRp nick@forge";
}
