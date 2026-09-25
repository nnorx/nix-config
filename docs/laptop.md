# forge: the laptop

A Framework Laptop 16: Ryzen AI 9 HX 370, the RTX 5070 graphics module, 32 GB of
RAM, and a 2 TB NVMe in the 2280 slot. NixOS owns that whole drive. The 2230 slot
is kept for a Windows drive later, for the few games whose anti-cheat will not
run under Proton.

Unlike every other host here, forge is not a server. It does not import
`hosts/common`, runs no sshd, and rebuilds itself rather than being deployed to.
See `hosts/forge/default.nix` for why.

| | |
|---|---|
| Disk | 1G ESP, then LUKS2, then btrfs with subvolumes for `/`, `/home`, `/nix`, `/var/log`, `/swap` |
| Swap | zram day to day, plus a 36G swapfile for hibernation |
| Lid | suspend, then hibernate after 2h |
| Graphics | Radeon iGPU by default, RTX module through PRIME offload |
| Boot | systemd-boot at install, then Lanzaboote for Secure Boot |
| Desktop | Plasma 6 on Wayland, Steam with Proton |

## Install

nixos-anywhere, run from WSL against the recovery ISO. It formats the disk with
`hosts/forge/disko.nix`, builds the system in WSL, copies it across, and writes
the machine's hardware config back into this repo.

### Before touching the laptop

1. **Generate the host key.** sops derives forge's age key from its SSH host
   key, and the recipient has to be in `.sops.yaml` before first activation or
   the account comes up locked ([recovery.md](recovery.md) explains why). forge
   has no sshd to create a key, so we create it here and install it with the
   system:

   ```bash
   dir=/dev/shm/forge-install                # tmpfs, so gone on WSL shutdown
   (umask 077; mkdir -p "$dir")
   mkdir -p "$dir/etc/ssh"     # 755, not 700: see below
   ssh-keygen -t ed25519 -N '' -C root@forge -f "$dir/etc/ssh/ssh_host_ed25519_key"
   nix shell nixpkgs#ssh-to-age -c ssh-to-age < "$dir/etc/ssh/ssh_host_ed25519_key.pub"
   ```

   Only `$dir` itself is private. nixos-anywhere copies this tree with its
   modes onto the new root, including over directories that already exist, so
   a 700 `etc` here would become a 700 `/etc` there, which only root can read.
   The key file carries its own 600.

   Add the printed recipient to `.sops.yaml` as `&forge` with its own rule, like
   the other hosts.

2. **Set the login password.** It is also the sudo password and the one the
   login screen asks for. The disk passphrase is separate.

   ```bash
   nix shell nixpkgs#mkpasswd -c mkpasswd -m yescrypt
   sops secrets/forge.yaml      # user-password-hash: <the hash>
   ```

   Then prove the new host key can decrypt it, before anything depends on that:

   ```bash
   SOPS_AGE_KEY=$(nix shell nixpkgs#ssh-to-age -c ssh-to-age -private-key \
     -i "$dir/etc/ssh/ssh_host_ed25519_key") sops -d secrets/forge.yaml
   git add .sops.yaml secrets/forge.yaml   # flakes see only tracked files
   ```

3. **Build and write the recovery ISO** as in
   [recovery.md](recovery.md#recovery-usb-x86). It already has sshd and the
   fleet key for root.

### On the laptop

4. In the firmware (F2): update the BIOS first if Framework has a newer
   release, while the factory Secure Boot keys are still in place. Then, under
   "Administer Secure Boot", set "Enforce Secure Boot" to Disabled so the ISO
   boots. Touch nothing else in that menu: the keys stay until the Secure Boot
   stage. Save with F10, and boot the stick from the F12 menu.

5. Get it online. An Ethernet expansion card is simplest. Otherwise `nmtui` on
   the console joins Wi-Fi. Use the trusted network, then read the address with
   `ip -br a`.

### From WSL again

6. Check the agent (`ssh-add -l`, and `ssh-add ~/.ssh/id_ed25519_pis` if it is
   empty), then check the disk and read the GPU bus IDs:

   ```bash
   ssh root@<ip> lsblk -d -o NAME,SIZE,MODEL        # exactly one NVMe, ~1.9T, nvme0n1
   ssh root@<ip> "nix-shell -p pciutils --run 'lspci | grep -E \"VGA|3D|Display\"'"
   ```

   Convert both bus numbers from hex to decimal (`c2:00.0` is `PCI:194:0:0`) and
   put them in `hosts/forge/graphics.nix`.

7. Install. The LUKS passphrase goes into a file that must **not end in a
   newline**: a newline would become part of the passphrase, and what you type
   at boot would never match it. That is what `printf '%s'` is for.

   ```bash
   key=/dev/shm/forge-luks.key               # NOT under $dir; see below
   (umask 077
    read -rsp 'LUKS passphrase: ' p; echo
    read -rsp 'Again: ' q; echo
    [ "$p" = "$q" ] && printf '%s' "$p" > "$key" && echo saved || echo 'MISMATCH, not saved')
   git add -A
   nix run github:nix-community/nixos-anywhere -- \
     --flake .#forge \
     --target-host root@<ip> \
     --generate-hardware-config nixos-generate-config hosts/forge/hardware-configuration.nix \
     --disk-encryption-keys /tmp/secret.key "$key" \
     --extra-files "$dir" \
     --option extra-platforms i686-linux \
     --phases kexec,disko,install
   shred -u "$key" "$dir/etc/ssh/ssh_host_ed25519_key"
   ```

   `--extra-files` copies everything under `$dir` into the new root, which is
   how the host key lands at `/etc/ssh/`. That is why the passphrase file lives
   outside `$dir`: inside it, the passphrase would be copied onto the laptop in
   plain text.

   `--phases` leaves out the final reboot, so the result can be checked under
   `/mnt` over the same SSH session before the stick comes out.

   The system is built in WSL, and Steam's 32-bit graphics stack needs a few
   i686 packages that are not in the binary cache. Nix builds i686 on any
   x86_64 host by default, but WSL's `/etc/nix/nix.custom.conf` sets
   `extra-platforms = aarch64-linux` for the Pis, which replaces that default.
   The last flag puts it back for this one command.

8. First boot: pull the stick, unlock the disk, and **log in at once**. A
   rejected password means sops did not decrypt; see recovery.md.

9. Commit the generated `hardware-configuration.nix` and the bus IDs.

Afterwards, by hand: copy the SSH keys you want from WSL (`id_ed25519_pis` for
the fleet, plus GitHub), and `~/.config/sops/age/keys.txt` if you will edit
secrets from here. Set Konsole's font to Cascadia Code NF, and clone this repo to
`~/projects/nix-config`.

The time zone is deliberately not declared, so it can change when the laptop
travels. It starts as UTC; set it once with
`timedatectl set-timezone America/New_York` or in System Settings, and again
wherever you are.

## Rebuilding

| | |
|---|---|
| `nrs` / `nrb` | Build `main` from GitHub, as on the fleet |
| `hms` | Build the local checkout. On other machines this runs standalone Home Manager; here Home Manager is part of the system, so it rebuilds that |

forge is not in `cache.yml`. Its closure includes NVIDIA's unfree driver, and
that cache is public.

## Secure Boot

Enable it after the install, in this order.

1. On forge: `sudo sbctl create-keys`. The keys go to `/var/lib/sbctl`, inside
   the encrypted volume.
2. Set `secureBoot = true` in `hosts/forge/boot.nix` and rebuild. Lanzaboote
   replaces systemd-boot and signs what it installs. Check with
   `sudo sbctl verify`. Unsigned `*-bzImage.efi` files left in `/boot/EFI/nixos`
   by the systemd-boot generations are harmless and can be deleted.
3. Put the firmware into Setup Mode. **On Framework, do this by hand**: under
   "Administer Secure Boot", open each of PK, KEK and DB Options and delete every
   entry, one at a time. **Do not use "Erase all Secure Boot Settings"**, which
   Framework firmware gets wrong. Leave dbx alone.
4. Back in NixOS, enroll:

   ```bash
   sudo sbctl enroll-keys --microsoft --firmware-builtin
   ```

   `--microsoft` adds Microsoft's certificates, both the 2011 set and the 2023
   set that current Windows boot media is signed with. Option ROMs, such as a
   graphics card's, are usually signed by Microsoft as well, and firmware that
   cannot verify one may refuse to boot. `--firmware-builtin` keeps
   Framework's own keys, which sign its BIOS updater.

5. Check that dbx still has entries (`ls -l /sys/firmware/efi/efivars/dbx-*`
   should not be tiny). Then in the firmware, turn on "Enforce Secure Boot".
   `bootctl status` should report `Secure Boot: enabled (user)`.

6. **Set a firmware admin password.** Without one, anyone at the keyboard can
   switch Secure Boot off.

fwupd's UEFI capsule updates may fail under our own keys. If one does, the fix
is to sign fwupd's EFI binary with sbctl.

Not done yet: unlocking the disk from the TPM. Windows dbx updates change the
PCR 7 measurement it would be sealed to, so it is better left until dual boot
has settled.

## Windows, later

Windows goes on its own drive in the 2230 slot, installed with the 2 TB drive
removed, so each OS has its own ESP and the F12 menu chooses between them. On
the NixOS side:

- **Re-check the GPU bus IDs** once the second drive is in. They can move, and
  a stale value makes offload silently do nothing.
- Drive renaming is harmless: NixOS finds its partitions by label, not by
  `nvme0n1`.
- If the firmware forgets the NixOS boot entry while the drive is out, boot it
  from F12, and `nrb` re-registers it. Put NixOS back first in the boot order;
  the Windows installer puts itself there.
- Microsoft can no longer update the KEK itself, because the platform key is
  ours. sbctl already enrolled the 2023 KEK, and dbx updates, which only need
  Microsoft's KEK, still apply.
- Unverified: whether kernel anti-cheat accepts Secure Boot with our own
  platform key. Reports say it only checks that Secure Boot is on. Test before
  relying on it.
