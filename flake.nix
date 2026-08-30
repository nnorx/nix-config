{
  description = "Nick's reproducible development environment";

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
    nixos-hardware.url = "github:NixOS/nixos-hardware";

    # Raspberry Pi 5 support (boot firmware, kernel, config.txt management)
    # Uses its own pinned nixpkgs fork — do NOT add nixpkgs.follows
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";

    # pimon — fleet monitoring agent
    pimon = {
      url = "github:nnorx/pimon";
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

  # Binary caches. Nix requires nixConfig to be a literal attrset — it cannot be
  # computed — so this list is duplicated in modules/baseline.nix and the two
  # must be kept in sync. baseline.nix is the one that matters on the hosts:
  # settings from a flake are client-supplied, so Nix discards them for any user
  # not in trusted-users, and honours them only with --accept-flake-config.
  # This copy covers evaluating the flake from a workstation, and a freshly
  # flashed host whose nix.conf does not yet know about these.
  nixConfig = {
    extra-substituters = [
      "https://nixos-raspberrypi.cachix.org"
      "https://nnorx-nix-config.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
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
      pimon,
      claude-plugins,
      improve,
      ...
    }:
    let
      # SSH public key for Pi access — single source of truth
      sshPubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEF1Tvp3mQjByFOSRh4uXWZhRkquB3n5oNoLspunq+OV nick@nix-config";

      # LAN topology — single source of truth for addressing (see lib/net.nix)
      net = import ./lib/net.nix;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Import nixpkgs once per system and reuse everywhere
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

      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f {
            pkgs = pkgsFor.${system};
            unstable = unstableFor.${system};
          }
        );

      # Helper function to create a NixOS configuration for any host
      mkHost =
        {
          hostname,
          system ? "aarch64-linux",
          extraModules ? [ ],
        }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {
            inherit hostname sshPubKey net;
            unstable = unstableFor.${system};
            pimonPkg = pimon.packages.${system}.default;
          };
          modules = [
            ./hosts/common
            ./hosts/${hostname}
            { system.configurationRevision = self.rev or self.dirtyRev or "unknown"; }
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.${hostname} = import ./home/common.nix;
              home-manager.extraSpecialArgs = {
                username = hostname;
                homeDirectory = "/home/${hostname}";
                unstable = unstableFor.${system};
              };
            }
          ]
          ++ extraModules;
        };

      # Raspberry Pi hosts — mkHost plus the SD-card boot and filesystem layout
      mkPi =
        {
          hostname,
          hardwareModules ? [ ],
          extraModules ? [ ],
        }:
        mkHost {
          inherit hostname;
          extraModules = [ ./hosts/common/pi.nix ] ++ hardwareModules ++ extraModules;
        };

      # Helper function to create an SD card installer image for Pi 3/4
      mkPiInstaller =
        hostname:
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
                  openssh.authorizedKeys.keys = [ sshPubKey ];
                };
                # Disable ZFS — not used on Pis, and its services hang during nixos-rebuild switch
                boot.supportedFilesystems.zfs = lib.mkForce false;
              }
            )
          ];
        }).config.system.build.sdImage;

      # Helper function to create a Home Manager configuration
      mkHome =
        {
          system,
          username,
          homeDirectory,
          homeModule ? ./home,
          extraModules ? [ ],
        }:
        home-manager.lib.homeManagerConfiguration {
          pkgs = pkgsFor.${system};

          modules = [
            homeModule
          ]
          ++ extraModules;

          extraSpecialArgs = {
            inherit username homeDirectory;
            unstable = unstableFor.${system};
            # Claude Code plugin marketplaces, keyed by the `name` field in each
            # marketplace's .claude-plugin/marketplace.json.
            claudeMarketplaces = {
              nnorx = claude-plugins;
              improve = improve;
            };
          };
        };
    in
    {
      # Formatter for `nix fmt`
      formatter = forAllSystems ({ pkgs, ... }: pkgs.nixfmt-tree);

      # Reusable devShells for common project types
      devShells = forAllSystems (
        { pkgs, unstable }:
        {
          # Fullstack development with Railway deployment
          fullstack = pkgs.mkShell {
            packages = [
              pkgs.nodejs_24
              unstable.pnpm
              pkgs.railway
            ];
            shellHook = ''
              echo "Fullstack dev shell ready (node $(node --version), $(railway --version 2>/dev/null || echo 'railway available'))"
            '';
          };

          # Playwright e2e testing with Nix-patched Chromium
          playwright = pkgs.mkShell {
            packages = [
              pkgs.nodejs_24
              unstable.pnpm
              unstable.playwright-test
            ];
            shellHook = ''
              export PLAYWRIGHT_BROWSERS_PATH="${unstable.playwright-driver.browsers-chromium}"
              export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS="true"
              echo "Playwright $(playwright --version) ready (chromium-only)"
              echo "Pin in package.json: @playwright/test@${unstable.playwright-driver.version}"
            '';
          };
        }
      );

      # Installer image for Pi 5 — includes SSH key for headless access
      # Build with: nix build .#packages.aarch64-linux.core5-installer --accept-flake-config
      packages.aarch64-linux.core5-installer =
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
              users.users.nixos.openssh.authorizedKeys.keys = [ sshPubKey ];
            }
          ];
        }).config.system.build.sdImage;

      # Installer images for Pi 3/4 — includes SSH key for headless access.
      # The image is host-agnostic: these three outputs are the same derivation,
      # and the host config is applied by nixos-rebuild after first boot.
      # Build with: nix build .#packages.aarch64-linux.{core4,lifeline}-installer --accept-flake-config
      packages.aarch64-linux.core4-installer = mkPiInstaller "core4";
      packages.aarch64-linux.lifeline-installer = mkPiInstaller "lifeline";

      # NixOS configurations for Raspberry Pis
      nixosConfigurations = {
        # Pi 5 uses nixos-raspberrypi for boot firmware + kernel support
        core5 = nixos-raspberrypi.lib.nixosSystem {
          specialArgs = {
            hostname = "core5";
            inherit nixos-raspberrypi sshPubKey net;
            unstable = unstableFor."aarch64-linux";
            pimonPkg = pimon.packages."aarch64-linux".default;
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
            ./hosts/common
            ./hosts/common/pi.nix
            ./hosts/core5
            { system.configurationRevision = self.rev or self.dirtyRev or "unknown"; }
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.core5 = import ./home/common.nix;
              home-manager.extraSpecialArgs = {
                username = "core5";
                homeDirectory = "/home/core5";
                unstable = unstableFor."aarch64-linux";
              };
            }
          ];
        };

        # Pi 3/4 use U-Boot via nixos-hardware
        core4 = mkPi {
          hostname = "core4";
          hardwareModules = [ nixos-hardware.nixosModules.raspberry-pi-4 ];
        };
        lifeline = mkPi {
          hostname = "lifeline";
          hardwareModules = [ nixos-hardware.nixosModules.raspberry-pi-4 ];
        };

        # The router. x86_64 and UEFI, so it takes mkHost directly rather than
        # mkPi, and brings its own hardware-configuration.nix.
        gate = mkHost {
          hostname = "gate";
          system = "x86_64-linux";
        };
      };

      # Home Manager configurations for different machines
      homeConfigurations = {
        # WSL configuration (also works on most Linux systems)
        "nick" = mkHome {
          system = "x86_64-linux";
          username = "nick";
          homeDirectory = "/home/nick";
        };

        # Raspberry Pi 5 configuration (common profile — no dev tools)
        "core5" = mkHome {
          system = "aarch64-linux";
          username = "core5";
          homeDirectory = "/home/core5";
          homeModule = ./home/common.nix;
        };

        # Raspberry Pi 4 configuration (common profile — no dev tools)
        "core4" = mkHome {
          system = "aarch64-linux";
          username = "core4";
          homeDirectory = "/home/core4";
          homeModule = ./home/common.nix;
        };

        # Raspberry Pi 4 configuration (common profile — no dev tools)
        "lifeline" = mkHome {
          system = "aarch64-linux";
          username = "lifeline";
          homeDirectory = "/home/lifeline";
          homeModule = ./home/common.nix;
        };

        # The router (common profile, x86_64)
        "gate" = mkHome {
          system = "x86_64-linux";
          username = "gate";
          homeDirectory = "/home/gate";
          homeModule = ./home/common.nix;
          # Installed from 26.05, unlike the Pis. Mirrors the override the
          # NixOS-embedded home-manager user gets in hosts/gate.
          extraModules = [ { home.stateVersion = "26.05"; } ];
        };

        # macOS configuration
        "nicknorcross" = mkHome {
          system = "aarch64-darwin";
          username = "nicknorcross";
          homeDirectory = "/Users/nicknorcross";
          extraModules = [ ./home/darwin.nix ];
        };
      };
    };
}
