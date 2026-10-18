# WireGuard public keys, the same model as lib/ssh-keys.nix: each private half
# is generated on its own device and never leaves it, except gate's, which is
# in secrets/gate.yaml because gate is rebuilt from this repo. Revoking a peer
# is deleting its line here and deploying gate. Nothing expires these keys, so
# that is the only revocation there is.
#
# A peer needs an address in net.segments.vpn.peers as well, and gate refuses
# to evaluate with a key that has none. An address without a key is just
# reserved.
{
  gate = "V0spPIhHBLve4miML74rMPWQ/fpa5sYczDFrhUt6XDM=";

  peers = {
    forge = "s7mFo68h82DgwfoyJ+a93TtioPIX6C8Cl3kj0oeEzBc=";
    phone = "CMCn/ZHvmY4k8W64c9WZKM8T5eA62IPjcHf+1qNq9XU=";
  };
}
