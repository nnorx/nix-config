# Home Assistant

Runs on core5 as a native NixOS service, from
[`modules/home-assistant.nix`](../modules/home-assistant.nix), at
`http://192.168.20.49:8123`. It replaces Google Home: lights, automations and,
in later phases, Zigbee buttons and voice, with no vendor cloud in the path.

Reachable from `trusted` only. core5 opens the port on its wired interface, and
gate forwards into `servers` from `trusted` in full but from iot and work only
on port 53, so no other segment can load it. There is no route in from outside the house yet;
that is inbound WireGuard on gate, which is not built.

## Native, and from `unstable`

Both decided on evidence; the module header has the detail.

**Native rather than a container**, the reverse of [UniFi](unifi.md). Home
Assistant is free software that Hydra builds, so the nixpkgs module gives a
declarative config and a closure CI can cache, with no Docker in the path.

**The package comes from `unstable`, not core5's own package set.** core5
evaluates against nixos-raspberrypi's nixpkgs, which replaces ffmpeg with
Raspberry Pi's fork. Home Assistant links ffmpeg, so on that package set it and
several of its Python dependencies miss cache.nixos.org and CI would rebuild
them. `unstable` carries no overlay and substitutes. The only thing built is the
Home Assistant package itself, with its test suite switched off.

## First run

From a machine on `trusted`, open `http://192.168.20.49:8123`.

1. **Create the owner account locally.** Nothing in onboarding needs a Home
   Assistant Cloud account, and none is wanted.
2. **Set the location, time zone and units here, in the UI.** They are
   deliberately absent from the Nix config: Home Assistant treats any of those
   keys in YAML as locking the whole location editor, and the house's
   coordinates do not belong in a public repo. They are kept in
   `/var/lib/hass/.storage`.
3. **Leave analytics off.** It is opt-in, so this means declining the prompt.

## Phones

Install the Home Assistant Companion app (iOS and Android) and point it at
`http://192.168.20.49:8123`. It works while the phone is on the trusted SSID and
not away from home, for the reason above.

Plain HTTP is acceptable while only trusted devices can reach the port. It stops
being acceptable the day anything else can.

## Adding an integration

**Add its domain to `extraComponents` first, then add it in the UI.** nixpkgs
builds Home Assistant with the Python dependencies of the listed integrations
and no others. An integration added in the UI without that fails at setup with
a missing module, not with a message that points here. The domain is the last
path segment of the integration's documentation URL.

The list replaces the module's default rather than extending it, which is why
the first four entries restate that default.

## What is state

Everything made in the UI lives in `/var/lib/hass`: users, integrations,
devices, dashboards, and the automations, scenes and scripts in their YAML files
there. `home-assistant_v2.db` is the recorder's history. None of it is in this
repo, and none of it is copied off-box yet.

`configuration.yaml` is the exception. It is a symlink into the Nix store,
rewritten on every start, so edits made to it on the host do not survive.

## Upgrades and rollback

**Home Assistant moves whenever `flake.lock` moves `nixpkgs-unstable`**, and
core5's automatic upgrade applies that at 05:00 without anyone present. Merge
lock bumps early in the day, as with any other.

**Treat an upgrade as one-way.** Home Assistant migrates the recorder database
forward on start and does not support downgrades. Rolling core5 back a
generation across a Home Assistant version change puts an older binary in front
of a newer schema. Before doing that, stop the service and restore a backup
taken by the older version, rather than rolling back blind.

## Troubleshooting

```bash
ssh core5 'systemctl status home-assistant; journalctl -u home-assistant -n 50'
```

core5 runs a 16K page-size kernel, so if Home Assistant or one of its
dependencies crashes in a way that makes no sense, suspect that first. Upstream
builds, and their memory allocators in particular, mostly assume 4K pages.
