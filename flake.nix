{
  description = "Nick's reproducible development environment";

  inputs = {
    # Use stable nixpkgs
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    # Unstable nixpkgs for bleeding-edge packages
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Home Manager for managing user environment
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Hardware-specific NixOS modules (Pi 3B, 4, etc.)
    nixos-hardware.url = "github:NixOS/nixos-hardware";

    # Raspberry Pi 5 support (boot firmware, kernel, config.txt management)
    # Uses its own pinned nixpkgs fork — do NOT add nixpkgs.follows
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";
  };

  # Binary cache for nixos-raspberrypi (pre-built Pi 5 kernel, firmware, etc.)
  nixConfig = {
    extra-substituters = [
      "https://nixos-raspberrypi.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
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
      ...
    }:
    let
      # SSH public key for Pi access — single source of truth
      sshPubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEF1Tvp3mQjByFOSRh4uXWZhRkquB3n5oNoLspunq+OV nick@nix-config";

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

      # Helper function to create a NixOS configuration for Raspberry Pis
      mkPi =
        {
          hostname,
          system ? "aarch64-linux",
          hardwareModules ? [ ],
          extraModules ? [ ],
        }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {
            inherit hostname sshPubKey;
            unstable = unstableFor.${system};
          };
          modules = [
            ./hosts/common
            ./hosts/${hostname}
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
          ++ hardwareModules
          ++ extraModules;
        };

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
          };
        };
    in
    {
      # Formatter for `nix fmt`
      formatter = forAllSystems ({ pkgs, ... }: pkgs.nixfmt-rfc-style);

      # Reusable devShells for common project types
      devShells = forAllSystems (
        { pkgs, unstable }:
        {
          # Playwright e2e testing with Nix-patched Chromium
          playwright = pkgs.mkShell {
            packages = [
              pkgs.nodejs_22
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

      # Installer image for Pi 4 — includes SSH key for headless access
      # Build with: nix build .#packages.aarch64-linux.core4-installer --accept-flake-config
      packages.aarch64-linux.core4-installer =
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

      # Installer image for Pi 3B — includes SSH key for headless access
      # Build with: nix build .#packages.aarch64-linux.core3-installer --accept-flake-config
      packages.aarch64-linux.core3-installer =
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

      # NixOS configurations for Raspberry Pis
      nixosConfigurations = {
        # Pi 5 uses nixos-raspberrypi for boot firmware + kernel support
        core5 = nixos-raspberrypi.lib.nixosSystem {
          specialArgs = {
            hostname = "core5";
            inherit nixos-raspberrypi sshPubKey;
            unstable = unstableFor."aarch64-linux";
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
            ./hosts/core5
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
        core3 = mkPi {
          hostname = "core3";
          hardwareModules = [ nixos-hardware.nixosModules.raspberry-pi-3 ];
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

        # Raspberry Pi 3B configuration (common profile — no dev tools)
        "core3" = mkHome {
          system = "aarch64-linux";
          username = "core3";
          homeDirectory = "/home/core3";
          homeModule = ./home/common.nix;
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
