# The 2 TB NVMe in the 2280 slot: a 1G ESP, then LUKS2 over btrfs.
#
# btrfs rather than ext4 for three things: transparent compression,
# subvolumes that keep /home apart from / and the store (so a snapshot tool
# added later can cover /home alone), and a swapfile inside the encrypted
# volume that hibernation can use without a second partition or a second
# passphrase. See boot.nix for the hibernation side.
#
# `device` is read only when disko formats. After that, boot and every mount go
# through disko's partition labels, so the Windows drive in the 2230 slot
# taking `nvme0` later changes nothing. It is not a /dev/disk/by-id path on
# purpose: that embeds the drive's serial, a hardware identifier this public
# repo keeps out, like gate's NIC MACs. docs/laptop.md checks `lsblk` for the
# right disk before anything is formatted instead.
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/nvme0n1";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            # The ESP holds the systemd-boot random seed, which bootctl warns
            # about if the mount is world-readable.
            mountOptions = [ "umask=0077" ];
          };
        };
        luks = {
          size = "100%";
          content = {
            type = "luks";
            name = "cryptroot";
            # Read once, at format time: nixos-anywhere copies the passphrase
            # here with --disk-encryption-keys. Boot asks for it interactively.
            # The file must not end in a newline, or the newline becomes part
            # of the passphrase and what is typed at boot never matches.
            passwordFile = "/tmp/secret.key";
            settings.allowDiscards = true;
            content = {
              type = "btrfs";
              extraArgs = [ "-f" ];
              subvolumes =
                let
                  mountOptions = [
                    "compress=zstd"
                    "noatime"
                  ];
                in
                {
                  "/root" = {
                    mountpoint = "/";
                    inherit mountOptions;
                  };
                  "/home" = {
                    mountpoint = "/home";
                    inherit mountOptions;
                  };
                  "/nix" = {
                    mountpoint = "/nix";
                    inherit mountOptions;
                  };
                  "/log" = {
                    mountpoint = "/var/log";
                    inherit mountOptions;
                  };
                  # Sized for hibernation: 32 GB of RAM plus headroom. zram in
                  # boot.nix outranks it, so day to day it is written only
                  # when hibernating.
                  "/swap" = {
                    mountpoint = "/swap";
                    swap.swapfile.size = "36G";
                  };
                };
            };
          };
        };
      };
    };
  };
}
