{
  description = "A homelab fleet (a router and three Pis) and the dev machines that run it";

  inputs = {
    # Use stable nixpkgs
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # Unstable nixpkgs for bleeding-edge packages
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Home Manager for managing user environment
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Hardware-specific NixOS modules (Pi 3B, 4, etc.)
    # Its modules use the host's nixpkgs. Its own is only for its tests, and
    # without this the lock pins a copy nothing here uses.
    nixos-hardware = {
      url = "github:NixOS/nixos-hardware";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Raspberry Pi 5 support (boot firmware, kernel, config.txt management)
    #
    # No nixpkgs.follows. Its kernel and firmware are built from its own
    # nixpkgs pin and served from its cache; following ours would make the
    # Pi 5 kernel ours to compile. core5's userland comes from our nixpkgs
    # anyway, passed to its nixosSystem (see core5 below), and that does not
    # move the kernel.
    #
    # `develop`, the project's default branch, is where its kernel and
    # firmware updates land and what its cache builds. `main` is not, so a
    # pin there keeps the Pi 5 kernel wherever that branch last stopped, and
    # the weekly flake update has nothing to move.
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/develop";

    # Declarative partitioning, used once, by nixos-anywhere, to lay out forge's
    # disk. Afterwards it only generates fileSystems from the same description.
    disko = {
      url = "github:nix-community/disko/latest";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Secure Boot for forge. Pinned to a release tag, as upstream recommends, so
    # the weekly lock bump never moves the signing stub underneath it.
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v1.1.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # sops-nix — age-encrypted secrets, decrypted at activation on each host
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # claude-plugins: personal Claude Code skills marketplace.
    # A plain git repo, not a flake, so it lands in the store as a source path
    # that ~/.claude/settings.json can point at directly.
    claude-plugins = {
      url = "github:nnorx/claude-plugins";
      flake = false;
    };

    # improve: shadcn's read-only codebase-audit skill. Ships as its own
    # marketplace, so it is consumed upstream rather than vendored.
    improve = {
      url = "github:shadcn/improve";
      flake = false;
    };
  };

  # Binary caches. nixConfig must be a literal attrset, so the list is written
  # here and modules/baseline.nix reads it into each host's nix.conf. This form
  # covers evaluating the flake from a workstation and a freshly flashed host.
  # nixos-raspberrypi's cache is CI's alone (cache.yml, core5's trustCaches):
  # each push carries the closure, so no host needs upstream's key.
  nixConfig = {
    extra-substituters = [ "https://nnorx-nix-config.cachix.org" ];
    extra-trusted-public-keys = [
      "nnorx-nix-config.cachix.org-1:/vn4K3PMf39c802pIvdiQ8ErecC5eTFuXxQ6/g6Sqro="
    ];
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      home-manager,
      nixos-hardware,
      nixos-raspberrypi,
      disko,
      lanzaboote,
      sops-nix,
      claude-plugins,
      improve,
      ...
    }:
    let
      # Public keys, one per admin machine: fleet SSH, the Pis' deploy login,
      # and the diag login.
      sshPubKeys = builtins.attrValues (import ./lib/ssh-keys.nix);
      deployPubKeys = builtins.attrValues (import ./lib/deploy-keys.nix);
      diagPubKeys = builtins.attrValues (import ./lib/diag-keys.nix);

      # Addresses, VLANs and ports: the one place they are written.
      net = import ./lib/net.nix;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      pkgsFor = nixpkgs.lib.genAttrs systems (
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = [
            # direnv 2.37.1 fish tests hang on macOS (Killed: 9)
            (final: prev: {
              direnv = prev.direnv.overrideAttrs (old: {
                doCheck = false;
              });
            })
          ];
        }
      );
      unstableFor = nixpkgs.lib.genAttrs systems (
        system:
        import nixpkgs-unstable {
          inherit system;
          config.allowUnfree = true;
        }
      );

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f pkgsFor.${system});

      mk = import ./lib/mk.nix {
        inherit
          self
          nixpkgs
          home-manager
          nixos-raspberrypi
          sops-nix
          claude-plugins
          improve
          pkgsFor
          unstableFor
          net
          sshPubKeys
          deployPubKeys
          diagPubKeys
          ;
      };
      inherit (mk)
        fleetSpecialArgs
        fleetModules
        systemModules
        mkHost
        mkPi
        mkHome
        pi4CachedKernel
        claudeMarketplaces
        ;
    in
    {
      checks.x86_64-linux = import ./tests {
        pkgs = pkgsFor.x86_64-linux;
        unstable = unstableFor.x86_64-linux;
        inherit net;
      };

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);

      apps = forAllSystems (
        pkgs:
        builtins.mapAttrs
          (_: drv: {
            type = "app";
            program = pkgs.lib.getExe drv;
            meta.description = drv.meta.description;
          })
          {
            preflight = pkgs.callPackage ./pkgs/preflight { };
            dns-top-domains = pkgs.callPackage ./pkgs/dns-top-domains { inherit net; };
            cve-scan = pkgs.callPackage ./pkgs/cve-scan { };
          }
      );

      packages =
        nixpkgs.lib.recursiveUpdate
          (import ./lib/images.nix { inherit nixpkgs nixos-raspberrypi sshPubKeys; })
          {
            x86_64-linux.unifi-drill = import ./lib/unifi-drill.nix {
              inherit nixpkgs net;
              core5 = self.nixosConfigurations.core5.config;
            };
          };

      nixosConfigurations = {
        # Not mkPi: core5's nixosSystem comes from nixos-raspberrypi (see
        # fleetSpecialArgs in lib/mk.nix). It shares the fleet's specialArgs
        # and modules, but not the call.
        #
        # `inherit nixpkgs` puts core5 on the fleet's nixpkgs. The wrapper
        # defaults to its own pin, which moves only when upstream bumps it.
        # The kernel and firmware still come from `nixos-raspberrypi.packages`,
        # built from that pin and cached upstream.
        #
        # The kernel runs 16K pages (base's bcm2712 kernel), but core5 leaves
        # out nixos-raspberrypi's page-size-16k module. Its only effect is an
        # overlay building jemalloc for 16K pages, and rustc links jemalloc,
        # so it moved the Rust toolchain and everything built with it off
        # cache.nixos.org. nixpkgs builds jemalloc for 64K pages on aarch64,
        # which works on a 16K kernel at some cost in memory.
        #
        # `nixos-raspberrypi` is deliberately absent from specialArgs: the
        # wrapper injects it and its own value wins the merge.
        core5 =
          let
            hostname = "core5";
            system = "aarch64-linux";
          in
          nixos-raspberrypi.lib.nixosSystem {
            inherit nixpkgs;
            trustCaches = false;
            specialArgs = fleetSpecialArgs { inherit hostname system; };
            modules = [
              (
                { nixos-raspberrypi, ... }:
                {
                  imports = with nixos-raspberrypi.nixosModules; [
                    raspberry-pi-5.base
                  ];
                }
              )
            ]
            ++ fleetModules { inherit hostname system; }
            ++ [ ./hosts/common/pi.nix ];
          };

        # Pi 4s boot U-Boot through nixos-hardware.
        core4 = mkPi {
          hostname = "core4";
          hardwareModules = [
            nixos-hardware.nixosModules.raspberry-pi-4
            pi4CachedKernel
          ];
        };
        lifeline = mkPi {
          hostname = "lifeline";
          hardwareModules = [ nixos-hardware.nixosModules.raspberry-pi-4 ];
        };

        # The router: x86_64 and UEFI, with its own hardware-configuration.nix.
        gate = mkHost {
          hostname = "gate";
          system = "x86_64-linux";
        };

        # The Framework 16 laptop. Not mkHost: hosts/common is the server fleet's
        # contract (username = hostname, static addressing from lib/net.nix, SSH as
        # the only way in), and a desktop that roams on Wi-Fi fits none of it.
        # hosts/forge imports the part that is genuinely shared,
        # modules/baseline.nix, and states the rest itself.
        #
        # Home Manager is embedded, like the fleet's, so one rebuild covers both,
        # but with the full dev profile and a real user rather than common.nix.
        forge =
          let
            hostname = "forge";
            system = "x86_64-linux";
          in
          nixpkgs.lib.nixosSystem {
            inherit system;
            specialArgs = fleetSpecialArgs { inherit hostname system; };
            modules = [
              ./hosts/forge
              nixos-hardware.nixosModules.framework-16-amd-ai-300-series-nvidia
              disko.nixosModules.disko
              lanzaboote.nixosModules.lanzaboote
            ]
            ++ systemModules {
              inherit system;
              username = "nick";
              homeModule = import ./home;
              extraSpecialArgs = { inherit claudeMarketplaces net; };
            };
          };
      };

      # Standalone Home Manager, for the dev machines without NixOS: WSL and
      # macOS. The NixOS hosts embed it and have no entry here.
      homeConfigurations = {
        "nick" = mkHome {
          system = "x86_64-linux";
          username = "nick";
          homeDirectory = "/home/nick";
          extraModules = [ ./home/wsl.nix ];
        };
        "nicknorcross" = mkHome {
          system = "aarch64-darwin";
          username = "nicknorcross";
          homeDirectory = "/Users/nicknorcross";
          extraModules = [ ./home/darwin.nix ];
        };
      };
    };
}
