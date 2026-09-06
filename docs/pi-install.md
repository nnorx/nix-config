# Installing and moving Pis

Flashing a new Pi, and migrating one to NVMe. For getting a broken host back,
see [recovery.md](recovery.md).

## Flashing a new Pi

The installer image is **host-agnostic**: `core4-installer` and
`lifeline-installer` are the same derivation. It boots as user `nixos` on DHCP
with the fleet SSH key, and the host identity is applied by `nixos-rebuild`
afterwards.

core5 is the exception. The Pi 5 needs `nixos-raspberrypi`'s own installer, so
`core5-installer` is a separate derivation.

1. Build the image, on any machine with Nix:

   ```bash
   nix build .#packages.aarch64-linux.lifeline-installer --accept-flake-config
   ```

   The output is **zstd-compressed**: `result/sd-image/*.img.zst`, about 1.3 GiB
   compressed and 3.1 GiB expanded.

2. Flash it. **Do not `dd` from WSL.** WSL2 cannot see USB card readers, and
   `/dev/sda`-`/dev/sdd` there are WSL's own virtual disks, one of which is its
   root filesystem. Flash from whichever OS owns the reader.

   **From Windows**, decompress somewhere Windows can read, then use Raspberry
   Pi Imager or balenaEtcher ("Use custom", pick the image):

   ```bash
   nix run nixpkgs#zstd -- -d result/sd-image/*.img.zst -o /mnt/c/Users/<you>/nixos-sd.img
   ```

   Current Raspberry Pi Imager reads `.img.zst` directly if you would rather
   skip the decompress step.

   **From a Linux host with the reader attached**, confirm the device with
   `lsblk` first, since `dd` asks nothing and cannot be undone:

   ```bash
   zstd -d result/sd-image/*.img.zst -o nixos-sd.img
   sudo dd if=nixos-sd.img of=/dev/sdX bs=4M status=progress conv=fsync
   ```

   Use 16 GB or larger. The image is ~3 GiB and NixOS expands the root partition
   on first boot, but `nix.gc` keeps 14 days of generations and a rebuild needs
   room for the old and new one simultaneously.

3. Boot the Pi and find its DHCP address. Pass the key explicitly, since a bare
   IP matches no `Host` block in `~/.ssh/config`:

   ```bash
   ssh -i ~/.ssh/id_ed25519_pis nixos@<dhcp-address>
   ```

   Do not go looking for a password: the `nixos` account has none, so the key is
   the only way in.

4. Low-RAM boards only (1 GB Pi 3B and similar), add temporary swap:

   ```bash
   sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
   ```

5. Build, stage, reboot. **Run these one at a time.** Pasted as a block,
   interrupting one leaves the shell to run the rest, including the reboot:

   ```bash
   sudo bash -c 'echo "nameserver 1.1.1.1" > /etc/resolv.conf'
   sudo nixos-rebuild build --flake github:nnorx/nix-config#lifeline --accept-flake-config --refresh
   sudo nixos-rebuild boot  --flake github:nnorx/nix-config#lifeline --accept-flake-config --refresh
   sudo reboot
   ```

   `boot` rather than `switch`: activation moves the host onto its static
   address from `lib/net.nix`, reconfiguring the very interface you are
   connected over. `boot` stages the generation and the reboot brings it up
   cleanly, and a failed boot leaves the previous generation selectable.

6. Reconnect at the static address and set a password:

   ```bash
   ssh <hostname>@<static-ip>   # address from lib/net.nix
   passwd                       # initialPassword is "changeme"
   ```

   SSH is key-only, so that password is only used for `sudo` and at the console.
   It is public in this repo, so changing it is not optional.

7. **Re-derive the host's sops age recipient.** A fresh install regenerates the
   SSH host key that the recipient is derived from, so `secrets/<host>.yaml`
   becomes undecryptable by that host until `.sops.yaml` is updated and
   `sops updatekeys secrets/<host>.yaml` is run. The failure surfaces later as
   an unrelated-looking deploy error.

   ```bash
   ssh-keyscan -t ed25519 <host> | cut -d' ' -f2,3 | ssh-to-age
   ```

## core5 boots from NVMe

Root and `/boot/firmware` live on the 1TB NVMe, addressed by UUID in
`hosts/core5/default.nix`. The SD card is still in the slot, still bootable, and
still holds the pre-migration system. It is the rollback, so leave it there. It
is also the reason a loose ribbon is dangerous rather than merely annoying: see
"The silent wrong boot" in [recovery.md](recovery.md).

**`BOOT_ORDER` is EEPROM state and Nix does not manage it.** A replacement
board, or an EEPROM reset, needs it set by hand:

```bash
sudo "$(nix build --no-link --print-out-paths nixpkgs#raspberrypi-eeprom)/bin/rpi-eeprom-config" \
  | tee ~/eeprom-current.conf
sed 's/BOOT_ORDER=0xf461/BOOT_ORDER=0xf416/' ~/eeprom-current.conf > ~/eeprom-new.conf
sudo "$(nix build --no-link --print-out-paths nixpkgs#raspberrypi-eeprom)/bin/rpi-eeprom-config" \
  --apply ~/eeprom-new.conf
```

`BOOT_ORDER` reads **right to left**. `0xf416` is NVMe, then SD, then USB, then
restart. Keeping the SD in the order rather than removing it is what makes a
failed NVMe boot fall through to a working system instead of to nothing.

Two things worth knowing before running that. `--apply` also flashes the
bootloader image shipped with the nixpkgs package, so it upgrades the firmware
as well as the config; that is the same thing `rpi-eeprom-update` does, but it
is a larger change than the one line in the diff. And `sudo` has no Nix in its
PATH, which is why the store path is resolved by the `$( )` first and `sudo` is
handed an absolute path.

## Migrating a Pi to NVMe

Use `nixos-install --root /mnt`, **not a `dd` clone**. Every NixOS Pi image
ships the same root label (`NIXOS_SD`) and the same fixed root UUID, so a block
copy leaves two filesystems that are indistinguishable to `by-label` and
`by-uuid` while both are attached. Fresh filesystems with new UUIDs avoid that
entirely.

**Two things must be carried across, not just the SSH keys.**

`/var/lib/nixos` holds NixOS's uid and gid allocation state. A fresh install
re-allocates from 1000 upward, so an account that was 1001 on the old root can
come back as 1000 on the new one. Declaring a uid does not move an existing
account, so any `users.users.<n>.uid` pinned to the old value then disagrees
with the account on disk, and home-manager refuses to activate with
`UID is "1000", expected "1001"`. That is what happened on core5, and why its
uid is pinned to 1000 today.

**Copy `/etc/ssh/ssh_host_*` to the new root before rebooting.** Each host's
sops age recipient is derived from its ed25519 host key, so a fresh install
regenerates it and `secrets/<host>.yaml` becomes undecryptable by that host.
Verify with:

```bash
ssh-keyscan -t ed25519 <host> | ssh-to-age   # must match .sops.yaml
```
