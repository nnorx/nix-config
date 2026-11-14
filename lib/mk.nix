# How flake.nix builds each kind of machine: the fleet's hosts, the Pis, and
# the standalone Home Manager configs.
{
  self,
  nixpkgs,
  home-manager,
  nixos-raspberrypi,
  sops-nix,
  claude-plugins,
  improve,
  pkgsFor,
  unstableFor,
  net,
  sshPubKeys,
  deployPubKeys,
  diagPubKeys,
}:
rec {
  # The specialArgs and modules every host gets, whichever nixosSystem builds
  # it, so a module added here reaches every host.
  #
  # Shared as pieces rather than behind one helper because core5 cannot go
  # through mkHost: it is built by `nixos-raspberrypi.lib.nixosSystem`, which
  # adds that flake's overlays to the package set and sets
  # `nixpkgs.hostPlatform` itself, so it must not be handed the `system`
  # argument mkHost passes.
  fleetSpecialArgs =
    { hostname, system }:
    {
      inherit
        hostname
        sshPubKeys
        deployPubKeys
        diagPubKeys
        net
        ;
      unstable = unstableFor.${system};
    };

  fleetModules =
    { hostname, system }:
    [
      ../hosts/common
      ../hosts/${hostname}
    ]
    ++ systemModules {
      inherit system;
      username = hostname;
      homeModule = import ../home/common.nix;
    };

  # What every NixOS host here gets, the fleet through fleetModules and forge
  # directly: secrets, the revision it was built from, and Home Manager
  # embedded for its one user. forge stays out of fleetModules because
  # hosts/common is the servers' contract, not because any of this differs
  # for it.
  systemModules =
    {
      system,
      username,
      homeModule,
      extraSpecialArgs ? { },
    }:
    [
      sops-nix.nixosModules.sops
      { system.configurationRevision = self.rev or self.dirtyRev or "unknown"; }
      home-manager.nixosModules.home-manager
      {
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
        home-manager.users.${username} = homeModule;
        home-manager.extraSpecialArgs = {
          inherit username;
          homeDirectory = "/home/${username}";
          unstable = unstableFor.${system};
        }
        // extraSpecialArgs;
      }
    ];

  mkHost =
    {
      hostname,
      system ? "aarch64-linux",
      extraModules ? [ ],
    }:
    nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = fleetSpecialArgs { inherit hostname system; };
      modules = fleetModules { inherit hostname system; } ++ extraModules;
    };

  # mkHost plus the SD-card boot and filesystem layout.
  mkPi =
    {
      hostname,
      hardwareModules ? [ ],
      extraModules ? [ ],
    }:
    mkHost {
      inherit hostname;
      extraModules = [ ../hosts/common/pi.nix ] ++ hardwareModules ++ extraModules;
    };

  # The Pi 4s' kernel: the Raspberry Pi bcm2711 kernel that nixos-raspberrypi
  # builds from its own nixpkgs pin and caches, as it does core5's. The one
  # nixos-hardware's module sets is built from our nixpkgs and is in no public
  # cache, so each nixpkgs bump would mean hours compiling it. A
  # nixpkgs.follows on that input would make this one ours to compile too.
  #
  # Only the kernel moves. U-Boot, extlinux and the device-tree filter stay
  # nixos-hardware's, and the dtbs come from this kernel. Its kernelPackages
  # default is mkDefault, so a plain value wins.
  pi4CachedKernel = {
    boot.kernelPackages = nixos-raspberrypi.packages.aarch64-linux.linuxPackages_rpi4;
  };

  # Claude Code plugin marketplaces, keyed by the `name` field in each
  # marketplace's .claude-plugin/marketplace.json. Shared by the standalone
  # Home Manager configs and forge's embedded one.
  claudeMarketplaces = {
    nnorx = claude-plugins;
    improve = improve;
  };

  # A standalone Home Manager configuration with the dev profile, for the
  # machines that do not run NixOS. The NixOS hosts embed theirs through
  # systemModules.
  mkHome =
    {
      system,
      username,
      homeDirectory,
      extraModules ? [ ],
    }:
    home-manager.lib.homeManagerConfiguration {
      pkgs = pkgsFor.${system};
      modules = [ ../home ] ++ extraModules;
      extraSpecialArgs = {
        inherit username homeDirectory;
        unstable = unstableFor.${system};
        inherit claudeMarketplaces net;
      };
    };
}
