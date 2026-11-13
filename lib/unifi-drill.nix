# The restore drill (docs/unifi.md, "Restoring"): core5's controller from
# modules/unifi.nix, on core5's pinned images, in a VM on forge with a fresh
# database. A package and never a check: the images are unfree, and every
# check is built on main and pushed to the public cache (tests/default.nix).
#
# The VM has no network but its UI, forwarded to forge's loopback. A restored
# controller holds the real devices' addresses and credentials, and must not
# reach them.
{
  nixpkgs,
  net,
  core5,
}:
let
  inherit (nixpkgs) lib;
  system = "x86_64-linux";
  pkgs = nixpkgs.legacyPackages.${system};
  hostname = "core5";
  ui = net.ports.unifiUi;
  ip = net.hosts.${hostname}.ip;
  guest = "10.0.2.15";

  # The images are core5's own, read from its config, so the drill follows its
  # pins. A new digest needs its amd64 archive's hash here, which the failed
  # build prints.
  hashes = {
    unifi-db = "sha256-FKl7iHZqEq+dMUWd3MZy80UQWF/TZ5S2PRta9in7uGA=";
    unifi = "sha256-N7mf8AexNgwbzLCMuoK5zAWDbML3iumZ1c2GUuro4Ug=";
  };

  pull =
    name: hash:
    let
      pin = lib.splitString "@" core5.virtualisation.oci-containers.containers.${name}.image;
      ref = lib.head pin;
      digest = lib.last pin;
      tag = lib.last (lib.splitString ":" ref);
      repo = lib.removeSuffix ":${tag}" ref;
    in
    {
      inherit ref;
      file = pkgs.dockerTools.pullImage {
        imageName = repo;
        imageDigest = digest;
        inherit hash;
        arch = "amd64";
        finalImageName = repo;
        finalImageTag = tag;
        # The digest in the name, so a bump with a stale hash fails the fetch
        # rather than finding the old image in the store under the same path.
        name = "${name}-${lib.substring 7 12 digest}.tar";
      };
    };

  # sops-nix, as far as modules/unifi.nix uses it, with a stand-in password.
  # The drill's database is fresh, so it never meets the real one.
  sopsStub =
    { lib, pkgs, ... }:
    {
      options.sops = {
        secrets = lib.mkOption {
          type = lib.types.attrsOf lib.types.attrs;
          default = { };
        };
        placeholder = lib.mkOption { type = lib.types.attrsOf lib.types.str; };
        templates = lib.mkOption {
          default = { };
          type = lib.types.attrsOf (
            lib.types.submodule (
              { name, config, ... }:
              {
                options.content = lib.mkOption { type = lib.types.str; };
                options.path = lib.mkOption {
                  type = lib.types.str;
                  default = toString (pkgs.writeText name config.content);
                };
              }
            )
          );
        };
      };
      config.sops.placeholder.unifi-mongo-password = "drill-mongo-password";
    };

  vm =
    (nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inherit net hostname; };
      modules = [
        "${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
        sopsStub
        ../modules/docker.nix
        ../modules/unifi.nix
        {
          system.stateVersion = core5.system.stateVersion;
          networking.hostName = "unifi-drill";
          time.timeZone = core5.time.timeZone;
          users.users.${hostname} = {
            isNormalUser = true;
            inherit (core5.users.users.${hostname}) uid group;
          };

          # QEMU's guest address, and core5's, which the module publishes the
          # ports on. QEMU forwards only to the first, so the UI is relayed
          # from it. No router: QEMU offers none with the network restricted.
          networking = {
            useDHCP = false;
            interfaces.eth0.ipv4.addresses = [
              {
                address = guest;
                prefixLength = 24;
              }
              {
                address = ip;
                prefixLength = 32;
              }
            ];
            firewall.interfaces.eth0.allowedTCPPorts = [ ui ];
          };
          systemd.services.docker-unifi = {
            after = [ "network-addresses-eth0.service" ];
            requires = [ "network-addresses-eth0.service" ];
          };
          systemd.services.unifi-drill-ui = {
            wantedBy = [ "multi-user.target" ];
            after = [ "network-addresses-eth0.service" ];
            requires = [ "network-addresses-eth0.service" ];
            serviceConfig = {
              ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:${toString ui},bind=${guest},fork,reuseaddr TCP:${ip}:${toString ui}";
              Restart = "always";
              DynamicUser = true;
            };
          };

          virtualisation = {
            restrictNetwork = true;
            forwardPorts = [
              {
                host.address = "127.0.0.1";
                host.port = ui;
                guest.address = guest;
                guest.port = ui;
              }
            ];
            graphics = false;
            cores = 2;
            memorySize = 4096;
            diskSize = 8192;

            # Loaded from the store and never pulled. The tag is only the name
            # the archive is loaded under; the digest is fixed by the fetch.
            oci-containers.containers = lib.mapAttrs (
              name: hash:
              let
                image = pull name hash;
              in
              {
                image = lib.mkForce image.ref;
                imageFile = image.file;
                pull = "never";
              }
            ) hashes;
          };

          # A console to check from, such as that nothing outside answers.
          services.getty.autologinUser = "root";
        }
      ];
    }).config.system.build.vm;
in
# Each run starts empty, and its disk, which holds the restored database and
# so the PSKs, is deleted when the VM exits.
pkgs.writeShellApplication {
  name = "unifi-drill";
  text = ''
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' EXIT
    echo "UniFi drill: https://127.0.0.1:${toString ui} once it is up. Ctrl-a x stops it."
    NIX_DISK_IMAGE=$dir/drill.qcow2 TMPDIR=$dir USE_TMPDIR=1 ${vm}/bin/run-unifi-drill-vm "$@"
  '';
}
