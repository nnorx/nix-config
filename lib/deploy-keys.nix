# SSH public keys for the Pis' deploy login (modules/deploy-agent.nix), one per
# admin machine, the same model as ./ssh-keys.nix: each private half is
# generated on its machine and never leaves it.
#
# A separate key from id_ed25519_pis, because sshd tells logins apart by key:
# this one is held to `deploy-agent` on the Pis and opens nothing else. Every
# machine keeps it at ~/.ssh/id_ed25519_deploy.
{
  wsl = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAYiJWeV2AgJ8vCS963Si2/vAqjhzpmkYQYVv2fBkGfl nick@wsl-deploy";
  forge = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIY+ilRvw0P+mGowBSxTHpLlj5z0AtFYPqnPBF7gBdsI nick@forge-deploy";
}
