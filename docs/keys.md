# Keys

Every key, token and password hash the fleet uses: what it is for, where it
is made and kept, how to rotate it, and what to do if it is lost or leaked.
Then what rebuilding forge from nothing needs that this repo does not hold.
Where a runbook has the steps, this points at it. The plan for hardware
security keys is in Linear's Keys & identity project.

This repo is public. Everything here is named by role and file, never by
value, and placed by host or service, never by physical location.

## The roots

- **The `nick` age key** decrypts every file in `secrets/` and every off-box
  backup in `homelab-state`. Kept at `~/.config/sops/age/keys.txt` on forge,
  in the password manager, and offline.
- **Nick's GitHub login.** Merging to main deploys the Pis that night.
- **Each host's SSH host key**, which is also its sops identity, so each host
  decrypts its own secrets and no other host's.

**Unrecoverable** marks a loss that cannot be undone once every copy is gone.
"Lost" means every copy, and "leaked" means someone else has one.

## The inventory

### SSH

| Key | For | Made | Held | Rotate | If lost | If leaked |
|---|---|---|---|---|---|---|
| Admin key, `id_ed25519_pis`, per admin machine (`lib/ssh-keys.nix`) | Each host's user, in wheel, sudo behind the password; root on the recovery ISO and Pi installers | On its machine, with a passphrase | Its `~/.ssh` and agent, hidden from commands (`lib/claude-sandbox.nix`) | README, "SSH access" | Use the other machine's. With none: a Pi takes a new line from main that night; gate from its console, or a recovery USB built with the new key | Delete the line, deploy gate, rebuild the images |
| Diag key, `id_ed25519_diag`, per admin machine (`lib/diag-keys.nix`) | fleet-ssh's `diag` login (`modules/diag-login.nix`) | On its machine, no passphrase: fleet-ssh reads the file, with no agent | Its `~/.ssh`, hidden from commands | README, "SSH access" | Make another, replace its line | Delete the line, deploy gate |
| Deploy key, `id_ed25519_deploy` (`lib/deploy-keys.nix`) | The Pis' `deploy` forced command (`modules/deploy-agent.nix`) | On its machine | Its `~/.ssh` and agent, hidden from commands | README, "SSH access" | Daytime deploys stop; the nightly upgrade is unaffected | Delete the line |
| Host key, `/etc/ssh/ssh_host_ed25519_key` | The host's SSH identity and its sops identity | sshd at first boot; forge's on WSL at install (laptop.md, step 1) | The host's `/etc/ssh`, root-only | Re-derive the recipient into `.sops.yaml`, `sops updatekeys` (README, "Secrets"). Copy it across a reinstall (pi-install.md) | The host cannot decrypt and locks every account at next activation (recovery.md). Recoverable while the age key is | A new host key and recipient, and new values in its sops file |
| Backup deploy key, `unifi-backup-deploy-key` (core5) | Both off-box pushes to `homelab-state` (`modules/offbox-push.nix`) | By hand, set into sops | `secrets/core5.yaml`; GitHub holds the public half | A new pair, `sops set`, swap the repo's deploy key | Pushes fail and alert. Make another | Rotate |

GitHub's own host key is pinned in `modules/offbox-push.nix`. It is public.

### WireGuard

| Key | For | Made | Held | Rotate | If lost | If leaked |
|---|---|---|---|---|---|---|
| gate's, `wireguard-private-key` (gate) | gate's end of every tunnel | `wg genkey`, into sops | `secrets/gate.yaml`; public half in `lib/wireguard-keys.nix` | New key and public half, deploy gate behind deploy-guard, rebuild forge, re-import the phone's config | Recoverable while the age key is | Rotate, and the PSKs |
| forge's, `/var/lib/wireguard/forge.env` | forge's peer (`segments.vpn.grants`) | On forge | forge alone, root-only | laptop.md, "Remote access" | Make a new one | Delete forge's line, deploy gate |
| The phone's | The phone's peer | On the phone | Its WireGuard app | README, "Remote access" | Make a new one | Delete its line, deploy gate |
| PSKs: `wireguard-psk-forge`, `wireguard-psk-phone` (gate), `wireguard-psk` (forge) | A symmetric layer over each handshake | `wg genpsk`, into sops | gate's file, forge's file, the phone's config | README, "Remote access", step 2; forge's pair from one `wg genpsk` | Regenerate | Regenerate |
| `wireguard-endpoint-host` (forge), `ddns-hostname` (gate) | Not credentials: names that resolve to the house | A random label | Those two files, and the record on Cloudflare | A new label in both, deploy gate, rebuild forge, delete the old record | Nothing lost | Rotate |

### age and sops

| Key | For | Made | Held | Rotate | If lost | If leaked |
|---|---|---|---|---|---|---|
| The `nick` age key, `&nick` in `.sops.yaml` | Every file in `secrets/`; every off-box backup (UniFi's carries the Wi-Fi PSKs) | On a dev machine, copied to each that edits secrets (laptop.md, "Afterwards") | `keys.txt` on forge, the password manager, offline | Below | **Unrecoverable** for backups encrypted to it alone. Each host's key still opens its own file, so root on each host can re-key it | Rotate, then change every value, below |
| Host age identities | Derived from the host key with ssh-to-age | | | | | |

`sops updatekeys` rewraps each file's data key for the recipients in
`.sops.yaml`, leaving values alone. It needs one identity that can already
decrypt the file.

**Rotating the age key.** `age-keygen` on the machine that will hold it,
replace the `&nick` anchor with its public half, and `sops updatekeys` each
file while the old key is still in `keys.txt`. `modules/offbox-push.nix` reads
the anchor, so the next push goes to the new key. Backups already pushed stay
on the old key: keep it while they matter.

**After a leak, rotating is not enough.** The old ciphertexts are in this
repo's history, so every value in every file changes, each as its row says.
What the backups carry, the Wi-Fi PSKs first, changes at its source.

### Tokens and API keys

| Token | For | Made | Held | Rotate | If lost | If leaked |
|---|---|---|---|---|---|---|
| `CACHIX_AUTH_TOKEN`, Actions secret (`cache.yml`, `cache-vm-tests.yml`) | Pushing to the `nnorx-nix-config` cache | Cachix's settings | Actions secrets | New token, replace the secret | Mint another; Pi upgrades fail when main's closure is not cached | Revoke it on Cachix |
| The cache's signing key | Signing the cache's paths, trusted via `nixConfig` (`modules/baseline.nix`) | Cachix, which holds it | Cachix | A new cache and public key | Cachix's to lose | A new cache |
| `FLAKE_UPDATE_TOKEN`, Actions secret (`update-flake.yml`) | Opens the weekly `flake.lock` pull request | GitHub's settings | Actions secrets | New token, replace the secret | Weekly bumps stop | Revoke it in GitHub's settings |
| gh's token, per signed-in machine | GitHub as Nick | `gh auth login` | gh's config or the keyring, hidden from commands | `gh auth login`, then revoke the old one in GitHub (logout only forgets it) | Sign in again | Revoke it, end web sessions |
| `linear-api-key` (forge) | The night shift's dispatcher, in its scoped teams | Linear's security settings | `secrets/forge.yaml`, read outside the sandbox | night-shift.md, "On forge" | Mint another | Revoke it in Linear |
| The Mac's Linear key | Work mode's issues | Linear's settings | The login keychain, `night-shift-linear` | night-shift.md, "Setting it up on the Mac" | Mint another | Revoke it in Linear |
| `ntfy-url` (core4, lifeline, core5, forge) | The fleet's ntfy.sh topic, whose name is the secret | `openssl rand` (README, "Alerts") | Those four files, the phone, healthchecks.io | README, "Alerts", then forge, the phone, healthchecks.io | Make a new topic | Make a new topic |
| `healthchecks-ping-key` (core4, lifeline, core5) | Pinging checks in the project | The project's settings | Those three files | README, "Alerts", second half | Mint another | Rotate |
| `cloudflare-api-token` (gate) | DNS edit on the one zone, for DDNS | Cloudflare's dashboard | `secrets/gate.yaml` | New token, `sops set`, deploy gate | The record stops following the WAN address | Revoke it, check the zone's records |
| Claude Code's login, `~/.claude/.credentials.json` | Claude sessions and the night shift | `claude`'s login | Each dev machine, hidden from commands on Linux | Sign in again, end the old session | Sign in again | End the session in the account |

Every other workflow job holds only its run's `GITHUB_TOKEN`, scoped by its
`permissions` block.

### Password hashes and application logins

| Credential | For | Made | Held | Rotate | If lost | If leaked |
|---|---|---|---|---|---|---|
| `user-password-hash` (all five hosts) | Console login and sudo; forge's login screen. Never SSH | `mkpasswd -m yescrypt` (laptop.md, step 2) | Each host's file, `/run/secrets-for-users` | New hash, deploy; `passwd` does not persist. Must be new (network.md, "Already disclosed") | Set a new hash. A Pi applies it nightly; gate needs the recovery USB | Rotate |
| `adguard-admin-hash` (core4, lifeline) | Nick's AdGuard login | bcrypt of a chosen password | Each resolver's file | `htpasswd -B`, `sops set`, deploy. Must be new | Set a new one | Rotate |
| `adguard-metrics-password`, `-hash` (core4, lifeline) | The collector's `metrics` login | Generated, a pair per resolver | Each resolver's file; read as a systemd credential | observability.md, "Secrets" | Regenerate | Regenerate |
| `grafana-admin-password` (core5) | Grafana's `admin` | Chosen, in the password manager | `secrets/core5.yaml`, and Grafana's database after first start | In Grafana's profile, then the secret (observability.md, "Secrets") | Grafana's CLI on core5 resets it | Rotate |
| `unifi-mongo-password` (core5) | The controller's MongoDB user | Generated | `secrets/core5.yaml`, and MongoDB's user record | Inside MongoDB first, then the secret (unifi.md, "First login") | Recoverable while the age key is | Rotate |
| UniFi's local admin | The controller | At first login (unifi.md) | The controller's database and backups | In the controller | A restore brings it back | Rotate, review the configuration |
| Wi-Fi PSKs, UniFi's device credentials | Each SSID; SSH on adopted devices | In the controller | Its database and backups, never this repo | In the controller | A restore brings them back | Rotate in the controller |
| Home Assistant's owner, each phone's session | Home Assistant | At onboarding (home-assistant.md) | Its state and backups | Its profile page, which also ends sessions | A restore brings it back | Rotate, end sessions |

The last four live only in application state, and leave the host only in the
off-box backups, encrypted to the age key.

### Boot and disk

| Credential | For | Made | Held | Rotate | If lost | If leaked |
|---|---|---|---|---|---|---|
| forge's LUKS passphrase | forge's whole disk | At install (laptop.md, step 7) | Typed at each boot | `cryptsetup luksChangeKey` | **Unrecoverable** for what is on forge alone: unpushed branches, worktrees, `.git/pr-handoff/`, `.git/night-shift/`, `~/.local/state/night-shift/` | With the laptop: "If forge was stolen", below |
| Secure Boot keys: sbctl's PK, KEK and db | What forge's firmware boots | `sbctl create-keys` | `/var/lib/sbctl`, encrypted | laptop.md, "Secure Boot", from step 1 | New keys and a re-enroll | New keys and a re-enroll |
| Firmware admin password | The firmware's settings | Chosen (laptop.md, "Secure Boot", step 6) | The firmware, the password manager | In the firmware | Secure Boot cannot be switched off, so the rescue USB does not boot | Change it |

### Hardware keys

forge has pcscd, age-plugin-yubikey and the FIDO2 tools
(`hosts/forge/hardware-keys.nix`). Claude's sandbox denies pcscd's socket,
`/run/pcscd`, and commands get a `/dev` with no `hidraw*` or `bus/usb`, so a
sandboxed command cannot reach a key.

### Accounts

Each account can mint, replace or revoke the credentials above that live in
it. Their logins are in the password manager, whose unlock is the root of
every "in the password manager" here.

| Account | Controls |
|---|---|
| GitHub | This repo and `homelab-state`: settings, merges to main, Actions secrets, the backup deploy key |
| Cloudflare | The zone and the DDNS token |
| Cachix | The cache, its signing key, push tokens |
| healthchecks.io | The heartbeats and where they notify |
| Linear | The night shift's queue, and its keys |
| The password manager | Copies of the age key, the passwords above, these logins |

## Rebuilding forge from nothing

### First, if forge was stolen

If forge was stolen, or its disk may have been read, revoke before
rebuilding. Powered off or hibernated, the disk is sealed by LUKS. Suspended,
its key was in memory, so treat a suspended loss as read.

1. gh's token, and any web session, in GitHub's settings. Claude Code's
   login, in its account.
2. forge's lines in `lib/ssh-keys.nix`, `lib/deploy-keys.nix` and
   `lib/wireguard-keys.nix`. Merge, deploy gate, rebuild any rescue image.
3. The Linear key, in Linear.
4. The age key: forge held a copy. Rotate it, then every value, as "After a
   leak" says. The tables are the checklist.

### Then, in order

laptop.md is the procedure; this is what to have at hand for it.

1. **A machine with Nix and an admin key the recovery ISO accepts.** With no
   admin machine left, add a fresh key to `lib/ssh-keys.nix` in a local
   checkout and build the ISO from that; it needs no merge.
2. **The password manager, unlocked**, for the age key, the firmware admin
   password and the account logins.
3. **The `nick` age key**, into `keys.txt` on the installing machine, for
   laptop.md's steps 1 and 2. Without it, forge's file starts over, and the
   two values it shares, the ntfy topic and the WireGuard PSK, come from
   core5's and gate's files through their host keys, as root on each.
4. **The firmware admin password**, to switch Enforce Secure Boot off so the
   ISO boots (laptop.md, step 4).
5. **New secrets made during the install:** a host key and recipient
   (step 1), a password hash (step 2), a LUKS passphrase (step 7).
6. **After the first boot**, laptop.md's "Afterwards": new admin and deploy
   keys, `gh auth login`, the `nick` key into `keys.txt`, a new WireGuard key,
   then deploy gate.
7. **Secure Boot**, from laptop.md's step 1.
8. **Claude Code's login.** The Linear key survives in `secrets/forge.yaml`,
   unless the theft list replaced it.
9. **A restore, if needed.** `gh repo clone nnorx/homelab-state`, since forge
   has no GitHub SSH key (`home/git.nix`), then unifi.md or
   home-assistant.md from the `git log` step.
