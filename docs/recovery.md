# Recovery

How to get a host back when it will not come back on its own. Three layers, in
the order you would reach for them: an automatic rollback that needs no
intervention, a bootloader generation you pick by hand, and a live USB for when
neither is reachable.

`gate` is the host this matters most for. Since the cutover it is the house's
only route to the internet, and the Nest is gone, so there is no fallback
router. A Pi that will not boot gets its card pulled and reflashed. gate boots
from an internal NVMe, so a generation that comes up without networking leaves
no way in except the stick.

## deploy-guard

`nixos-rebuild test` is the normal way to try a risky change without committing
to it: it activates without touching the bootloader, so a reboot undoes it. That
does not cover boot-time changes. Interface renames land in udev at device
enumeration, and initrd or bootloader changes never take effect at all, so those
need `boot` plus a reboot, which is precisely the form that can leave an
unreachable box.

[`modules/deploy-guard.nix`](../modules/deploy-guard.nix) closes that gap. Arm
before rebooting; if the new generation comes up and nobody confirms within the
window, the box returns itself to the generation that was running when it was
armed.

```bash
sudo deploy-guard arm 15
nrb && sudo reboot
# once you are back in:
sudo deploy-guard confirm
```

`deploy-guard status` says whether one is armed and which generation is running.

It is on gate only, not fleet-wide: the Pis are a card-pull away from recovery,
and gate is the host where an unreachable box means the house has no router. It
covers "boots, but is unreachable", which is the likely failure for networking
changes. It cannot help if the system does not boot far enough to start
services.

## Picking an older generation

Every `nixos-rebuild` leaves a generation and systemd-boot lists the previous
ones, so selecting one at the menu is how a deploy that breaks networking gets
undone by hand. `configurationLimit = 10` in `hosts/gate` keeps ten of them on
the ESP, which is capped at 953M and would otherwise fill during a run of
boot-and-reboot cycles.

The firmware timeout is short and not reliably catchable, which is part of why
the USB below sits ahead of the internal disk in the boot order.

## When sudo is the thing that broke

The fleet's login and sudo password is a sops secret, rendered into
`/run/secrets-for-users` early in activation, and `users.mutableUsers` is
false. That combination is what makes the password declarative rather than
whatever each host happened to be left holding, and it moves one failure into
a new place: if a host cannot decrypt its secret, the account has no usable
password, so console login and `sudo` both fail.

SSH still works, because authorized keys are declarative and do not depend on
sops. So the usual shape of this is a host you can reach and cannot escalate
on, which is recoverable but not from a shell on that host.

The likely cause is the host's SSH host key changing, since that is what its
age identity is derived from. Re-imaging does that. The fix is to re-derive the
recipient into `.sops.yaml` and run `sops updatekeys secrets/<host>.yaml`, as
[hosts/common](../hosts/common/default.nix) describes.

Confirm before assuming it:

```bash
systemctl status sops-install-secrets-for-users
ls -l /run/secrets-for-users/
```

On a Pi this is a card pull. On `gate` it is the USB below, because there is no
second route in.

## Recovery USB (x86)

**This does not install anything.** Nothing is written to the host: the USB
stick is the only thing flashed, gate's NVMe is untouched, and pulling the stick
and rebooting returns it exactly as it was. It is a rescue disk.

The image is the stock NixOS minimal ISO plus the fleet SSH key, which makes it
**headless**: it boots on DHCP with sshd running, so recovery is an SSH session
rather than a monitor and keyboard at the rack.

1. Build it (any machine with Nix):

   ```bash
   nix build .#packages.x86_64-linux.recovery-iso --accept-flake-config
   ```

   The output is `result/iso/*.iso`, 1.4 GiB. Any USB stick will do.

2. Write it. **Do not `dd` from WSL**: WSL2 cannot see USB card readers, and
   `/dev/sda`-`/dev/sdd` there are WSL's own virtual disks, one of which is its
   root filesystem.

   From Windows, copy it across and use balenaEtcher, which writes in DD mode by
   default and is what a hybrid ISO wants:

   ```bash
   cp result/iso/*.iso /mnt/c/Users/<you>/Downloads/nixos-recovery.iso
   ```

   Rufus works too but will ask, on seeing "ISOHybrid image detected": choose
   **DD Image mode**, not ISO mode. Afterwards Windows sees an unrecognized
   partition and offers to format the stick. Decline; the stick is fine, Windows
   just cannot read the filesystem.

   From a Linux host with the reader attached, confirm the device with `lsblk`
   first, since `dd` asks nothing and cannot be undone:

   ```bash
   sudo dd if=result/iso/*.iso of=/dev/sdX bs=4M status=progress conv=fsync
   ```

3. **USB precedes the internal disk in gate's boot order**, set during Phase 0.
   That is what makes recovery headless: plug the stick in, reboot over SSH, and
   it comes up in the live environment with no firmware interaction.

   ```bash
   ssh -i ~/.ssh/id_ed25519_pis root@<dhcp-address>
   ```

   **The cost of that ordering: a live stick left inserted boots the rescue
   image on every reboot**, which is indistinguishable from a broken deploy at
   exactly the moment you are least sure. Store the stick *with* the box, not
   *in* it.

4. To recover a broken host from it. **These are the only steps here that write
   to the host**, and they are for when something is already wrong:

   ```bash
   mount /dev/nvme0n1p2 /mnt && mount /dev/nvme0n1p1 /mnt/boot
   nixos-enter --root /mnt
   # then, inside:
   nix-env --list-generations --profile /nix/var/nix/profiles/system
   /nix/var/nix/profiles/system-<N>-link/bin/switch-to-configuration boot
   ```

   Reboot without the stick. Device names come from
   `hosts/gate/hardware-configuration.nix`.

## The silent wrong boot

core5's root is on NVMe with the SD card still in the slot as a fallback, and
the fallback works. That is the problem.

On 2026-09-04 the PCIe ribbon to the NVMe worked loose. The drive stopped
enumerating, the firmware fell through to the SD exactly as designed, and core5
booted the pre-migration system: healthy LEDs, link up, sshd running, zero
failed units. Nothing anywhere said "this is the wrong system". It was caught
only because that generation predated the VLAN cutover, so the box came back at
a retired address and a packet capture caught it ARPing for a gateway that no
longer exists.

Had the ribbon come loose before the renumber, core5 would have returned at the
right address running a two-week-old generation, serving stale config to the
fleet, and every external signal would have read normal.

**Do not remove the SD to fix this.** It is the only reason the box was
reachable and diagnosable with the drive gone, and every diagnostic that
identified the fault was run over SSH from the SD system. The defect is not that
the fallback exists, it is that falling back is **silent**. What is missing is
detection: something that notices a host's booted root device or running
generation is not the expected one and says so.

That is a monitoring requirement, tracked in Phase 8 of [router.md](router.md).
For the EEPROM `BOOT_ORDER` that makes the fallback work, see
[pi-install.md](pi-install.md).
