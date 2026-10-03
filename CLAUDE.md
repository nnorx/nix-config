# nix-config

One flake for a homelab fleet (gate, the router; core4, lifeline and core5,
the Pis) plus the dev machines: forge, the laptop, is NixOS with Home Manager
embedded, and WSL and macOS run Home Manager on its own. The README has the
layout and the fleet table. `docs/` has the runbooks: read the one for a host
before changing it.

## Checking a change

- `nix fmt` formats with nixfmt-tree. CI runs `nix fmt -- --ci .`. In the
  sandbox, pass `-- --no-cache`: treefmt's cache is outside what commands
  may write.
- `nix flake check --all-systems --no-build`.
- Also evaluate the toplevel of every host you touched, because `flake check`
  passes a host whose toplevel cannot evaluate at all:
  `nix eval --raw .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath`.
- For anything under `home/`, evaluate both Home Manager configs, `nick` (WSL)
  and `nicknorcross` (macOS), since either can break alone:
  `.#homeConfigurations.<name>.activationPackage.drvPath`.
- The x86 hosts, gate and forge, can be built locally with `nix build
  --no-link`; most of the closure comes from caches.
- The flake only sees files git tracks. `git add` a new file before evaluating.
- Do not build aarch64 closures locally. The Pi 4 kernel is in no public cache
  and takes hours to compile. `cache.yml` builds it on push to main.
- To check that a Pi can fetch its system for a commit, after `cache.yml` has
  run for it, ask the cache for the toplevel. `cache.yml` pushes whole
  closures, so the toplevel being there means the upgrade can substitute:

  ```
  p=$(nix eval --raw .#nixosConfigurations.<pi>.config.system.build.toplevel.outPath)
  nix path-info --store https://nnorx-nix-config.cachix.org "$p"
  ```

  A `nix build --dry-run` lists hundreds of derivations "to build" even then.
  The Pis' upgrade passes `always-allow-substitutes`, which NixOS's own
  generated files need (`modules/baseline.nix`), but the daemon ignores that
  option from anyone but a trusted user, and on forge only root is.
- Every commit changes every host's toplevel, through
  `system.configurationRevision`. To tell whether a change really touches a
  host, pin the revision and compare the two sides, with `<ref>` as
  `git+file://$PWD?ref=main` and then `git+file://$PWD`, the working tree.
  (`path:$PWD` fails in the sandbox, on the placeholders it mounts in
  `.claude/`.)

  ```
  nix eval --impure --raw --expr 'let c = (builtins.getFlake "<ref>").nixosConfigurations.<host>; in (c.extendModules { modules = [ { system.configurationRevision = c.pkgs.lib.mkForce "pinned"; } ]; }).config.system.build.toplevel.drvPath'
  ```

  This is how a PR says whether merging changes the Pis.

## Invariants

- Addresses, VLANs and ports live only in `lib/net.nix`, which
  `modules/net-assertions.nix` checks. Never hardcode any of them elsewhere.
- This repo is public. Secrets go in sops (`secrets/<host>.yaml`). Identifying
  data (WAN address, DDNS hostname, SSIDs, MAC addresses, DHCP reservations)
  goes nowhere in the repo, including commit messages and PR text. See "What
  stays out of this repo" in `docs/network.md`.
- Neither belongs in tool output either, since transcripts persist. Mask
  addresses and hostnames in logs before showing them.
- Secrets are Nick's to read and write. The sandbox denies the sops age key
  (`lib/claude-sandbox.nix`), so `sops` fails here by design; do not work
  around it.
  To add or change a secret, give Nick the command to run in his own terminal,
  not through `!`, whose output lands in the transcript. Write with
  `sops set --value-stdin` from a generator or a prompt that does not echo,
  and check by comparison (equal or not, length, shape), never by printing.
- Commands reach only GitHub, the flake registry and the cache
  (`home/claude.nix`). Any other host prompts or is refused. Say what was
  needed rather than retrying around it. nix builds run in the daemon, outside
  the sandbox, with full network, so the list is not enforced there: never use
  a build to reach a host it refuses.
- Name no vendor for personal accounts ("the password manager"), and keep prose
  about Nick's machines factual and neutral.
- Keys are per machine. Each SSH and WireGuard private key is generated on its
  own machine and never leaves it. Only the public halves are in the repo, in
  `lib/ssh-keys.nix` and `lib/wireguard-keys.nix`. gate's WireGuard key is the
  exception, in sops, because gate is rebuilt from this repo.
- The firewall is default-deny, and SSH is scoped per interface in
  `modules/firewall.nix`. Open a new port on a specific interface, never
  globally. What a WireGuard peer may reach is `grants` in
  `hosts/gate/wireguard.nix`, and nothing else.
- `users.mutableUsers = false`. Activation removes undeclared users and groups,
  and renaming a host's user replaces the account rather than renaming it.
- forge is a desktop and does not import `hosts/common`. It rebuilds itself and
  is not in `cache.yml`.

## Deploying and merging

Deploys and merges are Nick's. Do not run `nixos-rebuild switch` or `boot`,
`nrs`, `nrb`, `hms`, `deploy-guard`, or anything under `sudo`, on any host,
forge included.

Publishing is Nick's too. gh's login lives outside the sandbox, so commands
cannot push, open a PR or comment, and that is deliberate: a token in reach
of commands could merge to main as Nick, which deploys the Pis. Do not look
for a way to authenticate. When asked for a PR, commit, write the title and
body, and give Nick the commands to push and open it. The repo is public, so
PR and CI state can be read without a token from `api.github.com`.

Read-only diagnostics on a host go through `fleet-ssh <host> <command>`, the
one command that runs outside the sandbox (`home/ssh.nix`); plain `ssh` has no
route out of it. Keep each call to that single command: a pipe, a redirect or
`&&` keeps the whole call inside the sandbox, so filter on the remote side.
After a reboot the agent is empty until Nick runs `ssh-add`, and hosts refuse
the key until then.

- On forge, Nick can try a branch before merging with `hms`, which builds the
  local checkout.
- **Merging to main deploys the Pis that night.** They upgrade automatically
  from `github:nnorx/nix-config`. A merged change to addressing or interfaces
  reaches them unattended, possibly before gate is deployed to match. Check
  with the pinned comparison above, and say so in the PR when it applies.
- A change to the interface a deploy runs over needs `nrb` and a reboot, not
  `nrs`. gate has no fallback router, so its risky reboots and its firewall
  changes go behind `deploy-guard` (`docs/recovery.md`).
- `switch` does not start a newly added `network-addresses-<iface>` unit. The
  interface stays down until a reboot.
- Merge `flake.lock` bumps early in the day. A kernel rebuild in `cache.yml`
  takes 2 to 5 hours, and a Pi upgrade that runs before it finishes fails.

## Git and PRs

- Branch off main. One change per PR, and one host per PR when the change
  differs by host, unless the hosts must change together. PRs are
  squash-merged.
- Titles are `<scope>: <what changed>`, lowercase after the colon. The scope is
  a host, `fleet`, `pis`, `home`, `ci`, a module (`ssh`, `net-assertions`),
  `docs/<file>`, or `flake.lock`.
- The title says what changed. The body is wrapped prose saying why, and what
  was verified.
- Comments explain why and earn their length. No em dashes in new prose.
