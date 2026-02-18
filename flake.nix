{
  description = "Nick's reproducible development environment";

  inputs = {
    # Use stable nixpkgs
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    
    # Unstable nixpkgs for bleeding-edge packages
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    
    # Home Manager for managing user environment
    home-manager = {
      url = "github:nix-community/home-manager/release-24.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    
    # Claude Code - AI coding assistant (hourly updates)
    claude-code = {
      url = "github:sadjow/claude-code-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, home-manager, claude-code, ... }:
  let
    systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
    forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f {
      pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };
      unstable = import nixpkgs-unstable { inherit system; config.allowUnfree = true; };
    });

    # Helper function to create a Home Manager configuration
    mkHome = { system, username, homeDirectory }:
      let
        unstable = import nixpkgs-unstable {
          inherit system;
          config.allowUnfree = true;
        };
      in
      home-manager.lib.homeManagerConfiguration {
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = [ claude-code.overlays.default ];
        };

        modules = [
          ./home
        ];

        extraSpecialArgs = {
          inherit username homeDirectory unstable;
        };
      };
  in {
    # Reusable devShells for common project types
    devShells = forAllSystems ({ pkgs, unstable }: {
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
    });

    # Home Manager configurations for different machines
    homeConfigurations = {
      # WSL configuration (also works on most Linux systems)
      "nick" = mkHome {
        system = "x86_64-linux";
        username = "nick";
        homeDirectory = "/home/nick";
      };
      
      # Raspberry Pi 5 configuration
      "core5" = mkHome {
        system = "aarch64-linux";
        username = "core5";
        homeDirectory = "/home/core5";
      };

      # macOS configuration
      "nicknorcross" = mkHome {
        system = "aarch64-darwin";
        username = "nicknorcross";
        homeDirectory = "/Users/nicknorcross";
      };
    };
  };
}
