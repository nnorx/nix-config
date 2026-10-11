# Device identity

A decision record. Nothing here is built: it settles how gate and core5 can
name individual devices without this public repo saying which hardware they
are, so that the follow-up pull requests build it rather than re-argue it.

## The question

Several rules are segment-wide only because a device cannot be named. gate lets
any iot device answer Home Assistant on the Govee reply port
([`hosts/gate/govee.nix`](../hosts/gate/govee.nix)), and core5 accepts that
port from the whole iot subnet
([`hosts/core5/default.nix`](../hosts/core5/default.nix)). An iot egress
allowlist, if one comes, needs per-device identity too.

Naming a device in a rule takes a stable address. On iot that means a Kea
reservation, and a reservation is keyed on a MAC address, which "What stays
out of this repo" in [network.md](network.md) keeps out of the repo.

The header of `lib/net.nix` and that section of network.md kept one answer
open: move the file, or part of it, into a private flake input. This record
weighs that against the alternatives and decides against it.

## In short

| | Decision |
|---|---|
| Private flake input | None |
| A device's role and address | Public, in a new `devices` set in `lib/net.nix` |
| Its MAC address | gate's sops file, one key per device |
| Who can read the MACs | Nick's age key and gate's host key, as for every gate secret |
| What needs a MAC | Only Kea on gate. Firewall rules need addresses alone |
| CI, the Pis, the sandbox | Unchanged, with no new credential anywhere |
| Preflight | Unchanged. A MAC change shows as the brief's existing secrets note |
| First consumers | Kea reservations for the Govee lights, then the reply rule narrowed to them, on gate and then on core5 |

## What is identifying

The split rests on a line network.md already draws: RFC1918 addresses alone
are fine in public, and a per-device MAC table is not. A firewall rule never
needs the MAC. nftables and iptables match the address a device holds, and the
MAC matters only to the one service that hands that address out. So a device's
identity has two halves:

- **What a rule needs**: a role name, a segment, an address. Public.
- **What binds that address to hardware**: the MAC. Private.

Role names say what a rule needs and nothing more. `govee-1` is fine, because
govee.nix already says the house has Govee lights; a model number or a room is
not. A device whose existence alone should not be public does not get a
reservation. The dynamic pool serves anything no rule names, as it does today.

Everything else in "What stays out of this repo" is unaffected: the WAN
address, the DDNS hostname (already in sops), SSIDs.

## Options

### A private input, with a credential wherever it is evaluated

What each consumer would need:

- **gate.** `nrs` on gate fetches `github:nnorx/nix-config` there, so gate
  would hold a read token or deploy key for the private repo. Modest: gate
  already holds secrets.
- **The Pis.** Nothing, as long as their evaluation never reads the input,
  because Nix fetches inputs lazily. Tested with Nix 2.34 on forge: a flake
  whose locked input answers 404 still evaluates an output that does not read
  it, and fails only on one that does. But `net` reaches every host,
  [`modules/net-assertions.nix`](../modules/net-assertions.nix) checks the
  whole file on every host, and core5 has a Govee rule of its own. Keeping the
  data out of every Pi's evaluation is a property one stray reference breaks,
  and it breaks as a fetch failure in an unattended upgrade at night.
- **The cache.** cache.yml pushes the Pis' closures to a Cachix cache that
  anyone can read. A MAC that reached a Pi's closure would be published there,
  credential or not. So a private input could never serve core5 at all: its
  rule would have to stay segment-wide.
- **CI.** check.yml's flake check and preflight evaluate gate on every push
  and pull request, so the job would need a token, and a pull request from a
  fork, which gets no secrets, would fail. build-etc builds gate's /etc on
  pull requests, which would then hold Kea's config with every MAC in it, on a
  runner whose logs are public: one failing build that prints its input
  publishes the table.
- **The sandbox.** Commands reach GitHub with no GitHub login and no SSH
  agent, by design (CLAUDE.md), so Claude sessions and the night shift could
  no longer run preflight. Handing them a credential is what CLAUDE.md rules
  out.

What it buys is the data being visible to evaluation, where Nix could check
and transform it. The design below gets the checks that matter from the public
half. **Rejected**: a credential in every consumer, for a gain the alternative
gets without one.

### A private input over a public stub

The flake's input points at a public stub of the same shape, and only gate's
deploy passes `--override-input` for the real one. CI, the Pis and the sandbox
stay credential-free. The costs:

- What CI and preflight checked is not what gate runs. A commit to the
  private repo changes gate with no pull request, no preflight and no CI in
  between.
- A deploy that forgets the override installs the stub: Kea drops the
  reservations, and narrowed rules name the stub's addresses. Nothing at
  evaluation can catch that, since CI has to evaluate the stub cleanly.
- `system.configurationRevision`, and so host-status, names only the public
  commit, and "what is gate running" loses half its answer.
- gate still needs a credential for its own `nrs`.

**Rejected.** The review gap alone decides it.

### gate's sops file

gate already does this once. [`hosts/gate/ddns.nix`](../hosts/gate/ddns.nix)
renders the DDNS hostname, identifying for the same reason, into a sops
template at activation, so it never appears in the Nix config. MACs go the
same way.

- Nothing that builds from the public repo needs a credential. sops-nix
  decrypts on the host at activation, so CI, preflight and the sandbox
  evaluate and build gate without decrypting anything, and the Pis never read
  gate's file.
- A MAC change is a public commit of ciphertext, so it goes through a pull
  request like everything else. sops leaves key names in plaintext, so the
  diff says which device changed, and
  [`modules/sops-assertions.nix`](../modules/sops-assertions.nix) already fails
  evaluation when a declared secret has no key.
- No MAC ever lands in the Nix store, so none can reach a cache or a CI log.

The costs, accepted:

- Evaluation cannot see a MAC, so nothing checks its shape before a deploy. A
  malformed one makes Kea refuse its whole config, and DHCP stops on every
  segment; existing leases run out within the hour (`valid-lifetime` is 3600
  in `hosts/gate/routing.nix`). The command that writes the key checks the
  shape first (step 2 below), and a Kea failure is not a lockout: gate's own
  addresses are static and SSH does not depend on it.
- Only Nick can write the private half, since the sandbox denies the age key.
  Adding a device is his step: Claude writes the public half and hands him the
  command. Devices that need naming change rarely.
- Kea reads a config rendered under `/run` at activation, not one in the
  store. Preflight needs one adjustment for that, below.

**Chosen.**

### Segment-wide rules, as today

The baseline any option has to beat, and the sops design does: the reply rule
narrows from any iot device to the lights, for one sops key per light and
Kea's config rendered at activation.

How much it gains, stated plainly: an address on a shared segment is not
authentication. A compromised iot device can take a light's address, as it
could forge a light's MAC. What narrowing removes is the default, where any
device on iot can reach core5's Govee port without pretending to be anything.
It stops the casual and the accidental, not a device set on impersonating a
light.

## Decisions

### What goes where

`lib/net.nix` gains two attributes. The addresses here are illustrative:

```nix
# Devices a rule names: a role and an address, nothing that identifies the
# hardware. Each one's MAC, which Kea reserves the address for, is
# `mac-<name>` in secrets/gate.yaml.
devices = {
  govee-1 = { segment = "iot"; ip = "192.168.30.21"; };
  govee-2 = { segment = "iot"; ip = "192.168.30.22"; };
};

# The Govee lights, for the rules in hosts/gate/govee.nix and core5.
goveeLights = [ "govee-1" "govee-2" ];
```

Addresses sit below .100, the range `segments` already reserves for statics
and reservations, so they are outside the pool and Kea leases them to nothing
else. The lights are a named list, like `pimonAgents`, because a rule reads a
role, not "every device on iot".

`modules/net-assertions.nix` checks the new half the way it checks the rest:
each device's segment exists and has a pool, since a reservation needs Kea
serving there; its address is a host address in that segment, outside the
pool and not the gateway; no address is shared with a host, a VPN peer or
another device; and every `goveeLights` entry is a device on iot.

`secrets/gate.yaml` gains `mac-<name>` per device, and nothing else moves.

The header of `lib/net.nix` keeps the private input open on purpose. Step 1
replaces that with a pointer here.

### Public consumers

- **check.yml and cache.yml**: unchanged, with no credential. build-etc builds
  gate's /etc and its sops manifest, which carry placeholders, never a MAC.
- **The Pis**: unchanged. core5 reads the lights' addresses from `lib/net.nix`,
  so its rule narrows too, and its closure in the public cache holds addresses
  only. A private input could not have done that (above).

### Preflight and its brief

- **The public half is ordinary.** A device added or moved changes gate's Kea
  config and the rules that read it, and the brief says which units restart.
- **One adjustment, in the Kea pull request.** nixpkgs' Kea unit restarts on
  its config file's path. Once that path is the rendered file under `/run`,
  it never changes, so the brief would stop showing Kea restarting for any
  config change. The template's content in the store, placeholders and all, is
  added to Kea's `restartTriggers`, and the brief keeps reporting it.
- **A MAC change touches only `secrets/gate.yaml`.** The brief already says
  "Secrets change for gate. Evaluation cannot see inside them, so check they
  decrypt on the host", which is the right advice. The template's
  `restartUnits` restarts Kea on the host when the rendered file changes. The
  brief cannot predict that from evaluation, and need not: gate deploys only
  by hand.
- **Nothing that reads a MAC merges into an unattended deploy.** Every such
  consumer is on gate, which never upgrades itself. core5's rule does deploy
  the night it merges, which is why it comes last, below.

The brief's rules need no change.

### Where the private half lives

In `secrets/gate.yaml`, in this repo, encrypted to the `nick` and `gate`
recipients in `.sops.yaml`. Nick's age key and gate's host key can read it,
and nothing else: not CI, not the Pis, not the sandbox. The ciphertext and the
key names are public, as for every sops file.

No new repository. `homelab-state` is the private repo there is, but core5
holds a key that can write to it, so it is no place for configuration gate
trusts.

gate's disk already holds plaintext MACs: Kea's lease file records every
client's. Rendering a few into Kea's config adds nothing to what gate holds.

### The first two consumers

**Kea reservations, on gate.** `hosts/gate/routing.nix` gives each subnet in
`subnet4` a `reservations` list from the devices on its segment, with
`hw-address` from `config.sops.placeholder."mac-<name>"` and `ip-address` from
`lib/net.nix`. The settings go through `sops.templates."kea-dhcp4.conf"`,
owned by `kea` and restarting Kea, and `services.kea.dhcp4.configFile` points
at the rendered path, as ddns.nix does for its environment file. A light takes
its reserved address the next time it asks for one; a power cycle makes that
now.

**The Govee rules, on gate and then core5.** gate's reply rule gains
`ip saddr` of the lights and its command rule `ip daddr` of the lights. The
scan stays as it is, since it goes to the multicast group. core5's iptables
accept narrows from the iot subnet to the same addresses.

A light that is not in `devices`, such as a replacement, gets a pool address
and Home Assistant stops hearing it. That fails closed and visibly, and the
fix is adding the device.

## Migration order

One pull request per step. Nothing before step 5 reaches a Pi.

1. **`lib/net.nix` and `modules/net-assertions.nix`.** `devices`,
   `goveeLights` and their checks, and the header's pointer here. Nothing
   reads them yet, so no host's toplevel changes.
2. **Nick adds the MACs.** In his own terminal, once per light. The read does
   not echo, and the shape is checked before anything is written:

   ```bash
   read -rs mac && mac=$(printf '%s' "$mac" | tr A-F a-f) &&
     printf '%s\n' "$mac" | grep -qxE '([0-9a-f]{2}:){5}[0-9a-f]{2}' &&
     printf '"%s"' "$mac" | sops set --value-stdin secrets/gate.yaml '["mac-govee-1"]'; unset mac
   ```

   Committed before step 3 or as its first commit: once step 3 declares the
   secrets, `modules/sops-assertions.nix` fails evaluation until they exist.
3. **gate: Kea reservations.** Deployed by Nick. After it: Kea is active,
   `kea-dhcp4 -t /etc/kea/dhcp4-server.conf` passes, and each light holds its
   reserved address. The lease file has MACs in it, so count matches for the
   addresses rather than printing lines. Home Assistant still controls the
   lights, since no rule has changed yet.
4. **gate: narrow the Govee rules.** A firewall change on gate, so it goes
   behind `deploy-guard` ([recovery.md](recovery.md)). After it: Home
   Assistant discovers and controls every light, and the counters in
   `nft list chain inet nixos-fw forward-allow` move.
5. **core5: narrow its reply accept.** Merging deploys it that night, which is
   safe only once step 3 has the lights on their reserved addresses: before
   that, Home Assistant loses them unattended. Then tick the reservations item
   in [router.md](router.md).

Steps 4 and 5 do not depend on each other. Both depend on step 3.

## What would reopen this

- **A MAC, or other identifying value, needed inside a Pi's closure.**
  cache.yml publishes those closures, so neither this design nor a private
  input serves such a consumer without a private cache too. Work out what it
  is first; AdGuard's per-client settings, for one, can key on addresses,
  which are public.
- **`devices` growing into an inventory.** An egress allowlist that names most
  of iot would make the public role names a list of what is in the house. If
  it comes to that, decide whether role names move into sops too, at the cost
  of rules that read them at activation rather than at evaluation.
