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
    boot.kernelPackages = withKernelAttrs nixos-raspberrypi.packages.aarch64-linux.linuxPackages_rpi4;
  };

  # The Pi 4 resolvers are on Ethernet and have no use for a radio. Without
  # nixos-hardware's opt-in UART setup the Bluetooth chip never answers, and
  # its failed reset is logged every boot. A blacklist stops loading by alias
  # alone, so it names each module a device or socket would load: hci_uart and
  # btsdio for Bluetooth, brcmfmac for Wi-Fi.
  pi4NoRadios = {
    boot.blacklistedKernelModules = [
      "hci_uart"
      "btsdio"
      "btbcm"
      "btqca"
      "bluetooth"
      "brcmfmac"
      "brcmfmac_cyw"
      "brcmutil"
      "cfg80211"
    ];
  };

  # core5's kernel, the one nixos-raspberrypi's Pi 5 module sets at
  # mkDefault, restated to pass it through withKernelAttrs.
  pi5CachedKernel = {
    boot.kernelPackages = withKernelAttrs nixos-raspberrypi.packages.aarch64-linux.linuxPackages_rpi5;
  };

  # NixOS 26.11 reads `target` and `buildDTBs` from the kernel package, and
  # nixos-raspberrypi's kernels, built from its 26.05 pin, carry neither. This
  # adds both without changing the derivation, through `.override` as well,
  # since NixOS re-overrides the kernel for kernelPatches. Setting the options
  # instead fails on core5, even with mkForce. It goes once
  # nixos-raspberrypi's develop builds from 26.11, whose kernels carry both.
  withKernelAttrs =
    kernelPackages:
    let
      add =
        kernel:
        kernel
        // {
          target = "Image";
          buildDTBs = true;
          override = args: add (kernel.override args);
        };
    in
    kernelPackages.extend (_: super: { kernel = add super.kernel; });

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
