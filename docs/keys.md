# Keys

How the fleet's keys, tokens and password hashes are designed and run: what
each one is for, what it unlocks, where it is made and kept, how to rotate it,
and what losing or leaking it costs. Then the target state for moving the
roots onto hardware security keys, and what rebuilding forge from nothing needs
that this repo does not hold. Where a runbook already has the steps, this
points at it.

This repo is public. Everything here is named by role and file, never by
value, and is placed by host or service, never by physical location.

## The roots

Three credentials the rest depend on.

- **The `nick` age key.** It decrypts every file in `secrets/` and every
  off-box backup in `homelab-state`. It is kept at
  `~/.config/sops/age/keys.txt` on forge, in the password manager, and
  offline.
- **Nick's GitHub login.** Merging to main deploys the Pis that night, and gh's
  token on forge acts as this login.
- **Each host's SSH host key**, which is also its sops identity, so each host
  decrypts its own secrets and no other host's.

In the tables, **Unrecoverable** marks a loss that cannot be undone once every
copy is gone. "Lost" means every copy, and "leaked" means someone else has a
copy.

## The inventory

### SSH

| Key | Unlocks | Generated | Held | Rotate | Lost | Leaked |
|---|---|---|---|---|---|---|
| Admin key, `id_ed25519_pis`, one per admin machine (`lib/ssh-keys.nix`) | A shell as each host's user, which is in wheel, with sudo behind the password. Root on the recovery ISO, and passwordless sudo on a Pi installer image | On its machine, with a passphrase | That machine's `~/.ssh`, and its agent after `ssh-add`. `lib/claude-sandbox.nix` hides both from commands | README, "SSH access" | Delete its line and use the other machine's. With none left, a Pi takes a new line from main that night, and gate takes one from its console with the sudo password, or through a recovery USB built with the new key | A shell on every host, and root on any rescue image built while the line was listed. Delete the line, deploy gate, rebuild the images |
| Diag key, `id_ed25519_diag`, one per admin machine (`lib/diag-keys.nix`) | Each server's `diag` login: a shell outside wheel, with no sudo, no pty and no forwarding, in `systemd-journal` (`modules/diag-login.nix`) | On its machine, with no passphrase, since fleet-ssh reads the file and uses no agent | That machine's `~/.ssh`, hidden from commands as above. fleet-ssh signs with it, and nothing else does | README, "SSH access" | fleet-ssh from that machine is refused. Make another and replace its line | Reading what an ordinary user can on each server, the journal included, with no sudo to try. Delete the line, deploy gate |
| Deploy key, `id_ed25519_deploy` (`lib/deploy-keys.nix`) | The Pis' `deploy` login, a forced command: upgrade to main now, reboot when idle, hold or release the upgrade (`modules/deploy-agent.nix`) | On its machine | Its `~/.ssh` and agent, both hidden from commands as above | README, "SSH access" | Daytime deploys stop. The nightly upgrade does not use it | Deploy main early, reboot an idle Pi, or hold its upgrades until healthchecks.io notices the next day |
| Host key, `/etc/ssh/ssh_host_ed25519_key`, one per host | The host's identity to SSH clients, and its sops age identity: its own `secrets/<host>.yaml` and nothing else | By sshd at first boot. forge's on WSL at install (laptop.md, step 1), since forge runs no sshd | The host's `/etc/ssh`, root-only | Re-derive the recipient into `.sops.yaml` and `sops updatekeys` (README, "Secrets"). Copy it across a reinstall instead (pi-install.md) | The host cannot decrypt its secrets and locks every account at its next activation (recovery.md). Recoverable while the age key is | That host's secrets, every past revision of its sops file in this repo's history included. Posing as the host to a client, given the network path |
| Backup deploy key, `unifi-backup-deploy-key` (core5) | Read and write on the private `homelab-state` repo, for both off-box pushes (`modules/offbox-push.nix`) | By hand, then set into sops | `secrets/core5.yaml`. GitHub holds the public half as the repo's deploy key | A new pair, `sops set` into `secrets/core5.yaml`, and swap the deploy key in the repo's settings | Pushes fail and alert. Make another | Pushing to `homelab-state`, and reading backups that are ciphertext to the age key |

GitHub's own host key is pinned in `modules/offbox-push.nix`. It is public and
listed only so nobody goes looking for it.

### WireGuard

| Key | Unlocks | Generated | Held | Rotate | Lost | Leaked |
|---|---|---|---|---|---|---|
| gate's private key, `wireguard-private-key` (gate) | gate's end of every tunnel | `wg genkey`, into sops | `secrets/gate.yaml`. The public half is in `lib/wireguard-keys.nix` | A new key into sops and its public half into the lib file. Deploy gate behind deploy-guard, rebuild forge, and re-import the phone's config | Recoverable while the age key is | Posing as gate to a peer, given that peer's PSK and the network path. Both are in the same file |
| forge's private key, `/var/lib/wireguard/forge.env` | forge's peer: DNS, the AdGuard UI, SSH to the fleet and the internet through gate (`segments.vpn.grants` in `lib/net.nix`) | On forge | forge alone, root-only, in neither the repo nor sops | laptop.md, "Remote access" | Make a new one, as a reinstall does | Joining as forge from anywhere, given `wireguard-psk` too. SSH behind it still needs a fleet key. Delete forge's line and deploy gate |
| The phone's private key | The phone's peer: DNS alone | On the phone | The phone's WireGuard app | README, "Remote access" | Make a new one | DNS through the house, given its PSK |
| PSKs: `wireguard-psk-forge` and `wireguard-psk-phone` (gate), `wireguard-psk` (forge) | Nothing alone. A symmetric layer over each peer's handshake | `wg genpsk`, straight into sops | gate's file, forge's own copy in its file, and the phone's inside its config | README, "Remote access", step 2. forge's pair from one `wg genpsk`, kept equal | Regenerate | Nothing without the peer's private key |
| `wireguard-endpoint-host` (forge), `ddns-hostname` (gate) | Nothing. Not credentials: in sops because each is a name that resolves to the house | A random label | Those two files, and the record on Cloudflare | A new label in both, deploy gate, rebuild forge, then delete the old record on Cloudflare | Nothing is lost | The house's WAN address, to anyone who looks the name up (`hosts/gate/ddns.nix`) |

### age and sops

| Key | Unlocks | Generated | Held | Rotate | Lost | Leaked |
|---|---|---|---|---|---|---|
| The `nick` age key, `&nick` in `.sops.yaml` | Every file in `secrets/`, so every host's secrets. Every off-box backup: UniFi's, which carries the Wi-Fi PSKs and device credentials, and Home Assistant's | On a dev machine, and copied to each one that edits secrets (laptop.md, "Afterwards") | `~/.config/sops/age/keys.txt` on forge and any machine it was copied to, the password manager, and an offline copy | "Rotating the age key", below | **Unrecoverable** for the backups encrypted to it alone. The sops files survive: each host's key still opens its own file, so root on each host can re-key it to a new `nick` | Every secret in every file, every past revision in this public repo's history included, and every backup ever pushed. Rotating the key does not undo that |
| Host age identities | See the host key above. Each is derived from the host's SSH host key with ssh-to-age, so there is no separate key | | | | | |

Each sops file has its own data key, wrapped once per recipient in the file's
metadata. `sops updatekeys` rewraps it for the recipients `.sops.yaml` lists and
leaves the values alone, and it needs one identity that can already decrypt the
file.

**Rotating the age key.** Generate a new key with `age-keygen` on the machine
that will hold it, replace the `&nick` anchor in `.sops.yaml` with its public
half, and run `sops updatekeys` on each file while the old key is still in
`keys.txt`. `modules/offbox-push.nix` reads that anchor, so the next push of
each backup goes to the new key. Backups already pushed stay readable by the old
key alone: keep it while they matter, or re-encrypt them as the target state
below does.

**After a leak, rotating is not enough.** The old ciphertexts are public in this
repo's history and the old key opens them, so every value in every file has to
change. Each row in these tables says how. The backups cannot be recalled
either: what they carry, the Wi-Fi PSKs first, has to change at its source.

### Tokens and API keys

| Token | Unlocks | Generated | Held | Rotate | Lost | Leaked |
|---|---|---|---|---|---|---|
| `CACHIX_AUTH_TOKEN`, an Actions secret (`cache.yml`, `cache-vm-tests.yml`) | Pushes store paths to the `nnorx-nix-config` binary cache | Cachix's settings | GitHub's Actions secrets | A new token on Cachix, then replace the secret | Mint another. Until then, Pi upgrades fail whenever main's closure is not cached | Paths in a cache every host trusts as root (README, "CI and the binary cache"). Revoke it on Cachix |
| The cache's signing key | Signs the cache's paths, for every host whose `trusted-public-keys` lists it (`flake.nix`'s `nixConfig`, applied by `modules/baseline.nix`) | Cachix. The workflows hand Cachix no signing key, so it signs with one it holds | Cachix alone | A new cache, and a new public key in `nixConfig` | Cachix's to lose | As the token |
| `FLAKE_UPDATE_TOKEN`, an Actions secret (`update-flake.yml`) | Opens the weekly `flake.lock` pull request | A GitHub token Nick made | GitHub's Actions secrets | A new token in GitHub's settings, then replace the secret | The weekly bumps stop | Writes to this repository, within the token's scope. Revoke it in GitHub's settings |
| gh's token, on forge and each machine signed in | GitHub as Nick, within its scopes: pushing branches, and opening and merging pull requests | `gh auth login` | gh's config or the desktop keyring. `lib/claude-sandbox.nix` hides it from commands | `gh auth login` again. `gh auth logout` only forgets a token locally, so revoke the old one in GitHub's settings | Sign in again | As the GitHub login |
| `linear-api-key` (forge) | Linear as Nick, in the teams it is scoped to: read and write issues and comments | Linear's security settings | `secrets/forge.yaml`, read by the night shift's dispatcher alone, outside the sandbox | docs/night-shift.md, "On forge" | Mint another | Issues and comments in those teams, and work queued for the night shift. No reach into GitHub |
| The Mac's Linear key, for the night shift's work mode | Linear in the work workspace: read and update issues | Linear's settings | The Mac's login keychain, as `night-shift-linear` | docs/night-shift.md, "Setting it up on the Mac" | Mint another | As forge's, on the Mac |
| `ntfy-url` (core4, lifeline, core5, forge) | The fleet's ntfy.sh topic. The topic name is the only secret: anyone with it can read every alert and send one | `openssl rand`, in the README's "Alerts" block | Those four files, the phone's subscription, and healthchecks.io's notification setting | README, "Alerts", then forge's copy as docs/night-shift.md does it, the phone, and healthchecks.io | Make a new topic | Reading every alert, and faking or flooding them |
| `healthchecks-ping-key` (core4, lifeline, core5) | Pinging, and creating, any check in the healthchecks.io project | The project's settings | Those three files | README, "Alerts", its second half | Mint another | A ping for a job that did not run, which hides a stopped upgrade or backup |
| `cloudflare-api-token` (gate) | DNS edit on the one zone | Cloudflare's dashboard | `secrets/gate.yaml` | A new token, `sops set`, deploy gate. The template restarts the DDNS unit | The record stops following the WAN address, and peers lose the house when it next changes | Any record in the zone: the tunnel's name pointed elsewhere, where peers fail the handshake rather than connect, and DNS challenges for certificates in the zone |
| Claude Code's login, `~/.claude/.credentials.json` | The account Claude sessions and the night shift run on | `claude`'s own login | Each dev machine. On Linux, `lib/claude-sandbox.nix` hides it from commands | Sign in again, and end the old session in the account | Sign in again | Use of the account. No reach into the fleet |

Every other workflow job holds only its run's `GITHUB_TOKEN`, scoped by its
`permissions` block and gone with the run.

### Password hashes and application logins

| Credential | Unlocks | Generated | Held | Rotate | Lost | Leaked |
|---|---|---|---|---|---|---|
| `user-password-hash` (all five hosts) | Console login and sudo for the host's user. On forge, the login screen too. SSH never takes it | `mkpasswd -m yescrypt` (laptop.md, step 2) | Each host's file, rendered to `/run/secrets-for-users` | A new hash into the file, then deploy. `passwd` does not persist (`hosts/common/default.nix`), and the value has to be new (network.md, "Already disclosed") | Set a new hash. A Pi applies it at its nightly upgrade with no sudo. gate needs the recovery USB, since its console asks for the same password | Offline guessing against the hash. With a fleet SSH key as well, root |
| `adguard-admin-hash` (core4, lifeline) | Nick's AdGuard admin login on that resolver: filtering, upstreams and DNS rewrites, which can send the house's lookups anywhere until AdGuard's next start | bcrypt, of a password Nick chose | Each resolver's file | A new hash with `htpasswd -B` and `sops set`, then deploy. The value has to be new (network.md, "Already disclosed") | Set a new one | Offline guessing against the hash |
| `adguard-metrics-password`, `adguard-metrics-hash` (core4, lifeline) | The `metrics` login, a full AdGuard admin, since AdGuard has no read-only role | Generated, a pair per resolver | Each resolver's file. The collector reads the password as a systemd credential | observability.md, "The metrics login" | Regenerate the pair | As the admin login |
| `grafana-admin-password` (core5) | Grafana's `admin`: every dashboard and data source, so every metric the fleet keeps | Chosen, kept in the password manager | `secrets/core5.yaml`, and Grafana's own database after its first start | In Grafana's profile page, then the secret to match (README, "Metrics") | Grafana's CLI on core5 resets it | The fleet's metrics and Grafana's settings |
| `unifi-mongo-password` (core5) | The controller's MongoDB user, on the containers' private network | Generated | `secrets/core5.yaml`, and MongoDB's own user record | MongoDB's init hook sets it only on an empty data directory (unifi.md, "First login"), so the password changes inside MongoDB first and the secret after, or the controller cannot log in to its database | Recoverable while the age key is | The database, from the private network where only the controller is |
| UniFi's local admin | The controller: the network's configuration, the Wi-Fi PSKs and every adopted device | Chosen at first login (unifi.md) | The controller's database and its backups | In the controller | A restore brings back the one in the backup | The whole network's configuration |
| Wi-Fi PSKs, and the credentials UniFi sets on its devices | Joining each SSID. SSH on the adopted devices | In the controller | The controller's database and backups, never this repo (network.md) | In the controller | A restore brings them back | The segment each SSID bridges onto |
| Home Assistant's owner account, and each phone's app session | Home Assistant, and every device it controls | At onboarding (home-assistant.md). A session per phone at sign-in | Home Assistant's state, and its backups | Home Assistant's profile page, which also ends a phone's session | A restore brings it back | The house's devices |

The last four live only in application state, and leave the host only inside
the off-box backups, encrypted to the age key.

### Boot and disk

| Credential | Unlocks | Generated | Held | Rotate | Lost | Leaked |
|---|---|---|---|---|---|---|
| forge's LUKS passphrase | forge's whole disk: its copy of the age key, its host and WireGuard keys, the Secure Boot keys, gh's token, every worktree | Chosen at install (laptop.md, step 7) | forge's LUKS header, typed at each boot | `cryptsetup luksChangeKey` on the LUKS partition | **Unrecoverable** for what is on forge alone: unpushed branches and worktrees, `.git/pr-handoff/`, `.git/night-shift/`, `~/.local/state/night-shift/`. The repo, the sops files and the backups are elsewhere | With the laptop, everything on it |
| Secure Boot keys: sbctl's PK, KEK and db | Signing what forge's firmware will boot | `sbctl create-keys` on forge | `/var/lib/sbctl`, inside the encrypted volume | laptop.md, "Secure Boot", from step 1: new keys, Setup Mode, enroll | New keys and a re-enroll. The firmware can return to Framework's own keys | A boot chain forge accepts, for anyone who can also write its ESP |
| forge's firmware admin password | The firmware's settings, Secure Boot's included | Chosen (laptop.md, "Secure Boot", step 6) | The firmware, and the password manager | In the firmware | Secure Boot cannot be switched off, so the rescue USB does not boot on forge | Switching Secure Boot off at the keyboard |

### Accounts

Each account below can mint, replace or revoke the credentials above that live
in it. Their logins are in the password manager, whose own unlock is the root
of every "in the password manager" on this page.

| Account | Controls | Leaked |
|---|---|---|
| GitHub | This repo and `homelab-state`: their settings, merges to main, the Actions secrets (replaced, never read), and the backup deploy key | Everything this page describes, since merges to main deploy the Pis |
| Cloudflare | The zone, so the tunnel's name, and the DDNS token | Any record in the zone |
| Cachix | The cache every host trusts, its signing key, and push tokens | Paths every host substitutes |
| healthchecks.io | The heartbeats and where they notify | Alerts silenced, or faked |
| Linear | The night shift's queue, and its keys | Work queued for the night shift |
| The password manager | Copies of the age key, the passwords above, and these logins | Most of this page |

## The target state

Which of these move to a hardware security key, and how. Buying the keys is
Nick's, and the alternatives each choice was weighed against are given with it.

### What the pinned tools support

At `a64206c`, nixos-26.05 gives sops 3.13.3, age 1.3.2, age-plugin-yubikey
0.5.1, age-plugin-fido2-hmac 0.5.0, age-plugin-tpm 1.0.1, and OpenSSH 10.5p1
with libfido2 1.17.0.

- **sops** encrypts to plugin recipients and decrypts with plugin identities.
  A recipient of the form `age1<plugin>1...` runs `age-plugin-<plugin>` from
  PATH to wrap the data key, and an `AGE-PLUGIN-...` line in the key file is
  an identity (`age/keysource.go` in its source). So a hardware recipient goes
  in `.sops.yaml` next to `nick`.
- **age** runs the same plugins, for the off-box push and for restores.
- **The hosts** should not notice. Each recipient gets its own wrap of the data
  key, and a host unwraps its own with its host key, never touching the
  plugin's. That is to be proven before any host's file carries one, since a
  host that fails to decrypt locks its accounts (recovery.md).
- **age-plugin-yubikey** uses the PIV applet. The key is generated on the
  device and never leaves it, and touch and PIN policies are fixed per key when
  it is made. Encrypting to it needs the plugin but not the device. Decrypting
  needs the device, and pcscd on the machine.
- **age-plugin-fido2-hmac** works with any FIDO2 key that has the hmac-secret
  extension. Its own README calls it experimental until 1.0, and says the
  identity sits in the computer's memory while it decrypts. Its recipient can
  be a plain X25519 one, so encrypting needs no plugin at all.
- **age-plugin-tpm** binds to forge's TPM, so it dies with forge's mainboard.
  It cannot be the copy that survives losing forge.
- **OpenSSH** makes `ed25519-sk` keys, which need a touch for every signature
  by default. `-O resident` keeps the key on the device, so a new machine
  recovers it with `ssh-keygen -K`. `-O verify-required` adds the PIN, and
  `-O application=ssh:<name>` keeps several apart on one device. sshd verifies
  them without libfido2, and `modules/ssh.nix` restricts key exchange, ciphers
  and MACs but not key types, so every host, the recovery ISO and the
  installers accept them. git signs with them too (`gpg.format = ssh`).

### sops and backups

**Two hardware recipients beside `nick`, through PIV.** Each key gets an age
identity from age-plugin-yubikey, made on the device with `--touch-policy
always`, so nothing on forge can decrypt with it unnoticed while it is plugged
in, and `--pin-policy once`. Both recipients join every creation rule in
`.sops.yaml`, and `sops updatekeys` rewraps each file. That is one command per
file, needs only the `nick` key, and changes no value. Before the first host
file, a VM test decrypts a file carrying both kinds of recipient with a host
key alone, which is how this repo already proves what a host does.

PIV over FIDO2's hmac-secret because the age key guards everything on this
page: a key that never leaves the device beats one that passes through memory
on every decrypt, and a plugin marked experimental by its author. FIDO2-only
hardware would fall back to age-plugin-fido2-hmac.

**The off-box backups go to the same three recipients.**
`modules/offbox-push.nix` reads one `&nick` anchor and refuses anything else,
so it would read a list instead, and core5's push would carry
`age-plugin-yubikey` on its PATH. The plugin only wraps there: core5 still
holds nothing that can read a backup back.

**The history in `homelab-state` is re-encrypted once.** age cannot add a
recipient to a file already written, and that repo's history is append-only by
design (unifi.md). So each version already pushed is decrypted on forge and
committed again, encrypted to all three, under a new path such as
`unifi/archive/<date>.unf.age`. The files are small (a settings-only UniFi
backup is around 30 KB, Home Assistant's a few MB) and few, since a version is
pushed only when its hash changes, and old versions are what the restore
runbooks reach for ("`latest` is not always the one you want"). The job's
plaintext belongs in a tmpfs, and the runbooks learn the archive path. The
alternative, encrypting only new pushes to all three, leaves every older
version depending on `nick` alone.

**`nick` lives off forge's disk.** Once the hardware keys have edited a secret
and restored a backup in a drill, `keys.txt` on forge holds only the plugin's
identity lines, which name a device and slot and decrypt nothing without the
device. `nick` stays in the password manager and offline, as the third
recipient. Day to day, sops on forge decrypts through a hardware key, with a
touch per command.

In the target state, Claude's sandbox (`lib/claude-sandbox.nix`) also denies
pcscd's socket, `/run/pcscd`, and the FIDO2 device nodes if it exposes them, so
a sandboxed command cannot ask a key for a touch at all. The touch policy is the
second guard, not the only one.

### Signing

The Deploy pipeline project needs a signing key Nick holds and agents cannot
use. `docs/deploys.md`, when it exists, is where the pipeline's side is
described.

- **The key.** One `ed25519-sk` signing key per hardware key, resident, with
  `-O application=ssh:signing`, a touch per signature. Their public halves go
  in a new `lib/signing-keys.nix`, as the other public halves do.
- **Agents cannot use it.** The private key is on the device. The file on forge
  is a handle, useless without it, and every signature takes a touch, so an
  agent's attempt shows as an unexpected blink, not a signature.
- **What gets signed: deploy refs.** A squash merge makes a new commit on main,
  so a signature on a branch commit does not carry over to it. A tag signed by
  Nick on the main commit to deploy is what a Pi can check: Nick chose this
  commit.
- **Where the signers come from.** A Pi checks the tag against the signers in
  the system it is running, never the commit it is about to deploy. Adding a
  signer takes one deploy signed by an existing one.
- **Commits, if wanted, per repository.** Not `commit.gpgSign` in
  `home/git.nix`: agents commit as Nick through the same git config on forge,
  and every commit of theirs would wait on a touch.

### SSH

Which logins take a touch:

| Login | Touch | Why |
|---|---|---|
| Nick's, as each host's user (wheel) | Yes | It holds sudo |
| The Pis' deploy login | Yes | Deploying stays Nick's. One connection per host per deploy, through ControlMaster, rather than one per verb |
| The recovery ISO and the Pi installers | Yes | Built from the same list, and rare |
| fleet-ssh's diagnostics | No | Claude sessions run it all day |
| The alert agent's `triage` login ([fleet-agent.md](fleet-agent.md)) | No | It runs unattended, and its forced command only reads |
| core5's pushes to `homelab-state` | No | Unattended, with a host credential |

**The two paths are two logins.** sshd tells logins apart by key, as the deploy
login already does.

1. A diagnostics login on each server, `diag`, not in wheel and so with no
   sudo, in `systemd-journal` for the logs, and in `AllowUsers` beside the
   host's own user and, on the Pis, `deploy`. It takes a file key per admin
   machine, from `lib/diag-keys.nix`, kept at `~/.ssh/id_ed25519_diag`, each
   `restrict`ed to no pty and no forwarding. fleet-ssh uses that key and
   nothing else does: its own config, from the store, offers it alone, with
   no agent. host-status works as `diag`. Nothing it starts outlives its
   login (logind's `KillOnlyUsers`), and it does not use the nix daemon,
   which only wheel may. Built, in `modules/diag-login.nix` and
   `home/ssh.nix`.
2. The host's user takes only `ed25519-sk` keys, from `lib/ssh-keys.nix`.
3. CLAUDE.md's fleet-ssh section, and `deploy-agent.nix`'s note on which login
   fleet-ssh uses, describe the `diag` login. Built with the first.

Every login takes keys from its declared list alone. sshd does not read a
login's own `~/.ssh/authorized_keys` (`authorizedKeysInHomedir = false` in
`modules/ssh.nix`), so deleting a line from a lib file is the whole of
revoking that key. Built with the first.

A diagnostics key, leaked, reads what an ordinary user can on each host, and
has no sudo to try.

[fleet-agent.md](fleet-agent.md) plans a third login, `triage`, for the alert
agent. It is narrower than `diag`: a forced command with fixed verbs and
masked output, since a model reading device-chosen text should not get a
shell. `diag` stays the general read-only shell for fleet-ssh in Claude
sessions. Each takes its own key, file-backed and touch-free.

### How many keys

**Two, enrolled the same way.** Each holds its own PIV age identity, a recipient
in every rule and in the pushes, and resident `ed25519-sk` keys for the admin
login, the deploy login and signing. Each is a second factor on every account
above that takes one, GitHub first. The spare is kept apart from the primary
and from forge.

The spare unlocks everything the primary does, which is the point. Losing one is
deleting its lines from the lib files and `.sops.yaml` and removing it from the
accounts, with nothing to re-encrypt, since the other recipients remain. The
cost is that enrolling something new needs both keys at hand: a new account's
second factor does. A new recipient or authorized key needs only a public half.

Losing both still leaves `nick`, in the password manager and offline, which
opens every sops file and every backup. That is why it stays as a third
recipient rather than being retired outright. SSH falls back to each host's
console with the sudo password, and to a rescue ISO built with a fresh file
key.

### What stays as it is

- **Host keys**, and through them each host's sops identity. Hosts decrypt at
  activation with nobody there to touch anything.
- **core5's backup deploy key**, for the same reason.
- **The CI tokens.** They live in GitHub, and the hardware that guards them is
  the GitHub login's second factor.
- **WireGuard keys.** The kernel needs the private key itself, and no hardware
  path exists for it.
- **forge's disk passphrase.** A FIDO2 keyslot is possible, since forge's initrd
  runs systemd, but it makes the key something a thief may carry off with the
  laptop. laptop.md defers TPM unlock until dual boot settles, and this follows
  it.

### Order of work

One pull request each, in this order:

1. The sandbox denies `/run/pcscd`, and the FIDO2 device nodes if it exposes
   them, before a key is ever plugged into forge.
2. forge gets pcscd, age-plugin-yubikey and the FIDO2 tools.
3. The VM test, then both hardware recipients in `.sops.yaml` and
   `sops updatekeys` on each file, run by Nick.
4. core5's pushes to a recipient list, then the one-off archive job.
5. The `diag` login, and fleet-ssh moving to it, which came ahead of steps 3
   and 4, since it depends on neither. Then the `ed25519-sk` keys in
   `lib/ssh-keys.nix` and `lib/deploy-keys.nix`, then the file keys removed.
6. `lib/signing-keys.nix`, with the Deploy pipeline's verifier and its own
   runbook.
7. `keys.txt` reduced to the plugin's identity lines, after a restore drill
   with a hardware key.

## Rebuilding forge from nothing

### First, if forge was stolen

If forge was stolen, or its disk may have been read, revoke before rebuilding.
Powered off or hibernated, the disk is sealed by LUKS. Suspended, its key was in
memory, and forge suspends for two hours before it hibernates (laptop.md).
Treat a suspended loss as read.

1. gh's token, in GitHub's settings, and any web session there. Claude Code's
   login, in its account.
2. forge's lines in `lib/ssh-keys.nix`, `lib/deploy-keys.nix` and
   `lib/wireguard-keys.nix`. Merge, which reaches the Pis that night, deploy
   gate, and rebuild any rescue image.
3. The Linear key, in Linear.
4. The age key. forge held a copy, so it has leaked: rotate it, and then every
   value, as "After a leak" above says. This is the long one, and the tables
   are its checklist.

### Then, in order

What a reinstall needs that this repo does not hold. laptop.md is the
procedure, and this is what to have at hand for it.

1. **A machine with Nix and an admin key the recovery ISO accepts.** laptop.md
   runs the install from WSL. With no admin machine left, add a fresh key to
   `lib/ssh-keys.nix` in a local checkout and build the ISO from that. The image
   takes the list it is built with, so this needs no merge. With hardware keys,
   `ssh-keygen -K` brings a resident key back on any machine.
2. **The password manager, unlocked.** It holds the age key's copy, the firmware
   admin password and the account logins.
3. **The `nick` age key**, from the password manager or the offline copy, into
   `~/.config/sops/age/keys.txt` on the installing machine. laptop.md's steps 1
   and 2 re-key and edit `secrets/forge.yaml` with it. Without it, forge's file
   starts over with new values, and the two it shares, the ntfy topic and the
   WireGuard PSK, come from core5's and gate's files through their host keys,
   which takes root on each.
4. **The firmware admin password**, to switch Enforce Secure Boot off so the ISO
   boots (laptop.md, step 4).
5. **New secrets made during the install:** a host key and its recipient
   (step 1), a login password hash (step 2), and a LUKS passphrase (step 7).
6. **After the first boot**, laptop.md's "Afterwards": new admin and deploy keys
   into the lib files, `gh auth login`, the `nick` key into `keys.txt`, and a
   new WireGuard key into `lib/wireguard-keys.nix`, then deploy gate.
7. **Secure Boot**, from laptop.md's step 1: new sbctl keys, Setup Mode, enroll.
8. **Claude Code's login.** The Linear key survives in `secrets/forge.yaml`
   through `sops updatekeys`, unless step 3 of the theft list replaced it.
9. **A restore, if one is needed.** On forge, clone `homelab-state` with
   `gh repo clone nnorx/homelab-state`, since forge has no GitHub SSH key
   (`home/git.nix`), then follow unifi.md or home-assistant.md from the
   `git log` step.
