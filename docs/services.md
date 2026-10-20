# Services

A decision record. Its decisions are made ("Decided"), and nothing in it is
built yet. It settles how the house's web UIs are reached by name over TLS,
and how each is wired from one table in `lib/net.nix`, so that the follow-up
pull requests build it rather than re-argue it. This file changes no host.

## The question

Every UI is an address and a port:

| Service | Host | `ports` in lib/net.nix | Listens on | Serves |
|---|---|---|---|---|
| Home Assistant | core5 | `homeAssistant`, 8123 | Every address, the module's default | HTTP |
| Grafana | core5 | `grafana`, 3030 | core5's address | HTTP |
| AdGuard Home | core4, lifeline | `adguardWeb`, 3000 | Every address (`host = "0.0.0.0"`) | HTTP |
| UniFi controller | core5 | `unifiUi`, 8443 | core5's address, published by Docker | HTTPS, self-signed |

Read from `lib/net.nix` and the modules that bind each one
([`home-assistant.nix`](../modules/home-assistant.nix),
[`metrics.nix`](../modules/metrics.nix),
[`adguardhome.nix`](../modules/adguardhome.nix),
[`unifi.nix`](../modules/unifi.nix)) at `a64206c`, and confirmed on the hosts
on 2026-10-17 with `ss` over `fleet-ssh`. Each host opens these ports on its
wired interface, so trusted reaches them through gate and servers reaches them
directly. VictoriaMetrics' query UI, vmalert and Alertmanager listen on core5's
loopback and stay there, outside this record.

This record gives each a name and a certificate every browser and the
companion app trust, so every login is encrypted from the device to the
service's host. The phone reaches Home Assistant only at home, because its tunnel grant
is DNS only ([`hosts/gate/wireguard.nix`](../hosts/gate/wireguard.nix)), and
[home-assistant.md](home-assistant.md) holds plain HTTP acceptable only while
nothing but trusted devices can reach the port. Grafana over the tunnel waits
until it is missed ([observability.md](observability.md), "Access"). And each
service is wired by hand, across `lib/net.nix`, its host's firewall, `grants`,
the probes and the backups. The NAS will add more, Immich first.

## In short

| | Decision |
|---|---|
| Names | `<name>.<domain>`, one label per service, under a domain bought for this, its DNS in a Cloudflare account of its own. `<domain>` is in sops on each host that needs it, never in the repo |
| Answered by | Unbound on core4 and lifeline, as a static zone built from the registry. Not gate, and nothing in public DNS |
| Certificates | A public CA, through the ACME DNS-01 challenge, for one wildcard, `*.<domain>`, so no service's name reaches Certificate Transparency logs |
| ACME client | lego from nixpkgs, in a unit of the proxy module, with a new token that can edit `<domain>`'s DNS and nothing else. Not gate's DDNS token |
| Proxy | Caddy, one on each host with a UI: core4, lifeline, core5. Port 443 on the host's LAN address, opened on its LAN interface alone |
| Services' own ports | Loopback alone, closed on the LAN. The fallback is an SSH tunnel |
| Registry | `services` in `lib/net.nix`: name, host, port, segments, probe, backup |
| Tunnel grants | Move from `hosts/gate/wireguard.nix` into `lib/net.nix`, beside the peers' addresses, since the proxies enforce them too |
| Probes | An HTTPS probe per service from core5, alerting when one stops answering and when a certificate nears expiry. A DNS probe per name through public resolvers, alerting if public DNS ever answers one |
| Tunnel access | The phone gains Home Assistant. forge gains Grafana and keeps AdGuard. No peer gets UniFi, now enforced at evaluation |
| Logins | Each service keeps its own. No single sign-on |
| Order | Grafana first, then Home Assistant, UniFi and AdGuard, then gate's grants |

## What is identifying

The line is the one [network.md](network.md) draws in "What stays out of this
repo", and [device-identity.md](device-identity.md) applies: what a rule needs
is public, and what maps the repo to the house is not.

- **The domain is kept out.** A name under the DDNS zone names that zone,
  which is identifying. A domain bought for this is kept out too, so nothing
  in the repo leads to it: it goes in sops as `services-domain`, as the DDNS
  hostname does in [`hosts/gate/ddns.nix`](../hosts/gate/ddns.nix).
- **Labels are public.** `grafana`, `home-assistant`, `unifi`,
  `adguard-core4` and `adguard-lifeline` say what the repo already says, and
  live in `lib/net.nix`, where every consumer can read them.
- **No label reaches a certificate.** CT logs publish every name a public CA
  certifies, so a certificate for `adguard-core4.<domain>` would tie the
  domain to this repo, whose host names are distinctive. The one certificate
  is for `*.<domain>`, and nothing else ever is. The rule runs both ways:
  nothing in the repo appears in a certificate, and no certificate names
  anything in the repo.
- **Public DNS holds nothing.** The names exist only in the resolvers. The
  public zone carries the challenge's TXT record for the minutes an issuance
  takes, and nothing else, and core5 checks that it stays that way ("What
  reads it").

No port opens on gate's `wan`. DNS-01 proves control of the domain through the
DNS provider's API, not through a connection to the house.

## Names

### The domain

| | A public CA can certify it | In the repo |
|---|---|---|
| `home.arpa` (RFC 8375) | No | Yes |
| A subdomain of the DDNS zone | Yes | No |
| A domain bought for this | Yes | No |

**A domain bought for this**, a few dollars a year, its DNS at Cloudflare in
an account of its own, holding no records. Cloudflare scopes an API token to
zones, not records, so any token that can answer a challenge under the DDNS
zone can also move the record WireGuard peers dial, and that token would sit
on three Pis (below). Pointing the challenge's name at another zone by CNAME
would keep the token off the DDNS zone, but needs a second zone anyway, so it
gains nothing over a domain of its own. An account of its own, with its own
login, goes one step further: a token made in it cannot be given the DDNS
zone at all, and neither login reaches the other's zones. A domain of its own
also keeps the wildcard's CT entry off the DDNS zone. `home.arpa` suits only the private CA,
below.

The services sit one label under it, `<name>.<domain>`, so the one wildcard
covers all of them, and a new service never needs a new certificate.

### Where they are answered

**Unbound on core4 and lifeline**, as a static local zone for `<domain>` with
an A record per service, at its host's address. Static, like the suffixes
[`modules/unbound.nix`](../modules/unbound.nix) already keeps local, so a name
the registry does not hold is NXDOMAIN at the resolver rather than a lookup
sent to Cloudflare. Every segment that resolves through the fleet, and every
tunnel peer, asks these two. guest asks public resolvers and gets nothing,
which is right, since it can reach none of the services.

The domain is kept out of the store, so the zone cannot be in Unbound's
settings. It is a sops template, rendered at activation from the registry with
`services-domain` as a placeholder, which Unbound reads through `include:` and
which restarts Unbound when it changes. NixOS's module already skips its
build-time `unbound-checkconf` on both resolvers, as it does whenever remote
control is configured, which the cache dump uses, so the include costs no
check that runs today.
The VM test that comes with it, using a stand-in domain, is the check.

**Not gate.** gate's Unbound binds loopback and answers gate alone, and
nothing on gate asks for these names.

**Not AdGuard's rewrites**, which network.md once named for local names, and
which `modules/adguardhome.nix` could splice the domain into, through the
config it already renders at start. Rewrites keep answering while the host's
Unbound is down and AdGuard is on its public fallback, which a static zone
does not. But a rewrite answers only the names it lists, so anything else
under `<domain>` would go out to Cloudflare, and the names belong beside the
other names the house answers itself. An Unbound outage on one resolver fires
`ResolverFailing`, and costs these names only there, until it is fixed.

The challenge's own lookups would meet that static zone, so lego checks
propagation through `net.publicResolvers` (`--dns.resolvers`), never the
house's. core5 resolves through them already. The CA validates from outside,
where the zone is public.

`dns-top-domains` reads the resolvers' query logs, and sessions run it. With
every client asking for `<name>.<domain>`, its output would print the domain
near the top. So it counts a name answered with a fleet address as
`(local name)`, as it does `.lan`, judging by the answer, since it cannot know
the domain. That lands with the zone.

## Certificates

### The options

| | Public CA, ACME DNS-01 | Private CA |
|---|---|---|
| Clients | Every device and app trusts it already | A root installed on every device that opens a UI, by hand on each phone |
| Names | Under a registered domain kept in sops, so its consumers splice it in at activation | Under `home.arpa`, public, evaluated like the rest of `lib/net.nix` |
| Credentials on hosts | A DNS token for the services' zone, on each proxy host | None, while the root stays offline and leaves are signed by hand |
| What leaves the house | Each issuance and renewal: the CA and the DNS provider's API, about every two months, and `*.<domain>` in CT logs | Nothing |
| Renewal | Automatic | By hand, yearly; or automatic, with a CA online on a host |
| A stolen credential costs | The DNS token: the names, published and served with a trusted certificate to devices off the fleet's resolvers. A certificate key: the same, wherever its holder answers a device's DNS | Every name, to every device that trusts the root, unless the client enforces a name constraint |

### A public CA, chosen

The point of this change is that whoever opens Home Assistant, on whatever
device, gets a page the browser and the app trust. A private root makes that a
step on every device, and a device that missed it shows a certificate
warning, which teaches clicking through. Once installed, a root is trust in
whatever its key signs, which is wider than five services unless a name
constraint narrows it, and not every client enforces one. A public CA asks
nothing of any client.

What it costs falls on the repo and the hosts, where it is built once and
tested:

- **Four consumers splice the domain in at activation**, since it is not in
  the store: Unbound's zone, Caddy's site names, lego's request and core5's
  probe. Evaluation cannot see the domain, as it cannot see a MAC, and the VM
  tests use a stand-in.
- **A token on each proxy host**, which a domain of its own keeps to these
  names.
- **What leaves the house grows**: the CA and the DNS provider's API, from
  each proxy host. gate's `servers-egress` already lets the fleet's hosts out,
  so gate needs no rule, and [privacy.md](privacy.md) gains the rows with the
  first proxy.

Let's Encrypt, through lego's `cloudflare` DNS provider. A wildcard needs
DNS-01, which is also what keeps this free of any inbound port.

### The private CA, and Android

The other option, recorded for "What would reopen this". A root generated
offline and kept there, constrained to `home.arpa`, signing a leaf for each
host by hand from a key generated on that host, a year at a time (Apple
accepts at most 825 days from a root a user installed). Or step-ca on a host,
issuing short-lived leaves over ACME, which makes renewal automatic and puts a
key every client trusts on that host. Its root would go:

- **On forge**, declaratively: the system store, Firefox's policy, and Brave's
  own store.
- **On Android**, by hand, in Settings. Since Android 7, an app trusts a
  user-installed CA only if it opts in. Chrome does. **The Home Assistant
  companion app does**: its network security config has trusted user
  certificates since home-assistant/android#194, in December 2019, read for
  this record. So does Immich's, the NAS's first service: its network security
  config has trusted user certificates since immich-app/immich#25802, in
  February 2026, and its API requests have gone through the platform's own
  HTTP client since #25942, read on 2026-10-18. Firefox for Android does only
  with a setting turned on. Android then warns that the network may be
  monitored.
- **On iOS**, as a profile, with full trust switched on in Settings.
- **On every other device that opens a UI**, each by hand.

Its renewal failing looks as it does below, but the fix needs Nick and the
offline key.

### The token

**A new token, not gate's.** gate's `cloudflare-api-token` edits the DDNS
zone, and the services' zone is another. Even under the DDNS zone, reusing it
would copy gate's credential onto three Pis that upgrade themselves nightly
and run far more than gate does, and from any of them it could move the record
peers dial. The new token is owned by the services' account, has DNS edit on
`<domain>`'s zone and nothing else, and is `services-dns-token` in the sops
file of each proxy host.

A stolen copy is worth more than certificates. It edits the zone, so its
holder can publish records for the services' names and serve them, with a
wildcard certificate every client trusts, to any device that does not ask the
fleet's resolvers: a guest, or a phone off its tunnel. Inside the house the
static zone answers first, so the house's own lookups are untouched. Revoking
is deleting the token at the DNS provider, and the probe below says when it is
needed: published records are the one use of the token that shows.

A stolen certificate key is the smaller case. With no zone access, it serves
the names only where its holder also answers a device's DNS, such as a
network the phone joins with its tunnel down. That leaves nothing in public
DNS for a probe to see, and costs a new key and certificate once known.

### Issuing and renewing

**lego, in a unit of the proxy module's own, on each proxy host.**

- **Not Caddy's ACME client.** Caddy reaches a DNS provider only through a
  plugin, which nixpkgs builds as a fixed-output derivation that fetches Go
  modules. That is a hash to update whenever Caddy moves, and a build that
  fetches from hosts the sandbox refuses, which CLAUDE.md rules out, so no
  session could run a VM test containing it. It would also put the token in
  the long-running process that faces the LAN.
- **Not NixOS's `security.acme`**, which drives lego but writes the domain
  into the unit's command line, in the store. It is the right tool if the
  domain is ever public ("What would reopen this").
- **lego** is in nixpkgs and built by Hydra. The version pinned, 4.35.2, needs
  no contact address, takes the domain and the token from an environment file
  that sops renders, writes under a fixed file name whatever the domain,
  renews when a third of the certificate's life is left (`--dynamic`) or when
  the CA's renewal information says to, and runs a hook after a renewal,
  which reloads Caddy. The account's key and the certificate's are made on the
  host and never leave it, like every key here.

The unit runs at boot and daily. lego asks the CA when to renew, and asks for
a certificate only when one is due. Caddy's reload passes `--force`, as
NixOS's module does already,
so it reads the new files although its configuration has not changed. Three
hosts ask for the same wildcard, which stays under the CA's limit on duplicate
certificates, five a week at Let's Encrypt.

### When renewal fails

For weeks, nothing a person sees: the current certificate serves until it
expires. The unit is in `fleetAlerts.failure`, so its first failed run sends a
push, and `CertificateExpiring` fires with two weeks left. The causes are a
token revoked or expired, the DNS provider's API or the CA down, or the WAN
down, and only the first needs more than waiting: a new token in sops.

At expiry, every UI on that host fails its TLS handshake. Browsers show an
interstitial, the companion app refuses to connect, and the probes fail.
Nothing else stops. DNS, Home Assistant's automations, the UniFi devices and
the metrics carry on, because nothing but people's browsers and apps goes
through the proxy. Until a new certificate arrives, each service is reachable
by an SSH tunnel to its loopback port, below.

Two weeks is the margin on a 90-day certificate, which lego starts renewing
with 30 days left. Public certificates are getting shorter, to 47 days at most
by 2029 under the CA/Browser Forum's rules. A third of 47 is 16 days, so the
alert would then fire two days into failed renewals, still with two weeks to
fix them.

## The proxy

### Caddy, over nginx

Both are in nixpkgs and built by Hydra. The domain decides it. Caddy
substitutes `{$VAR}` from its environment when it loads its configuration, so
the Caddyfile Nix writes names `{$SERVICES_DOMAIN}` and an environment file
from sops supplies it. NixOS's Caddy module only formats the Caddyfile at
build, so nothing at build needs the value. nginx has no such substitution in
a server name, so its configuration, or an include, would be rendered by sops
at activation, without the check `nginx -t` gives it at build.

Beyond that, Caddy passes websockets, which Home Assistant and UniFi use, and
sets `X-Forwarded-For`, without being told, and its `remote_ip` matcher is the
per-service allowlist below. It manages no certificate here: each site's
`tls` names lego's files.

### One on each host with a UI

On core4, lifeline and core5, not one for the fleet.

- **A UI depends on its own host alone.** AdGuard's is wanted most when DNS
  misbehaves, and behind a proxy on core5 it would need core5 too.
- **Nothing crosses the LAN in plaintext.** Each proxy reaches its services on
  loopback, so they can bind loopback. A fleet proxy on core5 would carry
  AdGuard's logins across servers in the clear, and keep port 3000 open to it.
- **One module, everywhere.** `hosts/common` imports it on every host the
  registry names, as it imports `resolver.nix` on every host in
  `net.resolvers`, and each copy reads only its own host's services.

The cost is three hosts that each hold the token and obtain and renew the same
wildcard.

### Binding

Caddy binds the host's LAN address, port 443, and nothing else. No port 80:
its HTTP-to-HTTPS redirects are off, since browsers try HTTPS first for a name
typed without a scheme, and a listener that only redirects is one more to
keep. Its admin API, which `caddy reload` uses, is a unix socket rather than
its default TCP port on loopback, where any process on the host could replace
its configuration. The firewall opens 443 on the host's LAN interface
(`networking.firewall.interfaces.<iface>`), never globally.

443 is HTTPS's port, fixed by the protocol like SSH's 22 and DNS's 53, which
modules write where they use them, and it stays out of `ports`. It could not
go in: net-assertions' one-number-one-name check would refuse it beside
`wireguard`, which is UDP 443 on gate's `wan`.

Each site answers only the sources the registry allows: its `segments`'
subnets, the peers granted it, and the metrics collector, for its probe.
Anything else gets a 403 before the request reaches the service, so from
servers only the collector's probe reaches a UI.

### The services' own ports

**Loopback, and closed on the LAN.** Grafana's `http_addr`, AdGuard's web
`host` and UniFi's published UI port move to `127.0.0.1`, and Home Assistant
binds loopback if the version core5 runs still lets it choose. The firewall
closes each port regardless, and the proxy module asserts that no service in
the registry has its port open on its host's LAN interface.

**Not kept as a fallback.** A fallback that works keeps a plaintext login in
use without anyone noticing. The fallback is the one VictoriaMetrics' query UI already has (README, "Metrics"):

```bash
ssh -L 3030:127.0.0.1:3030 core5    # then http://localhost:3030
```

Home Assistant's port stays open for one step of the migration, until the
phone points at the new name. UniFi's inform, STUN and discovery ports are the
switch's and the AP's, and do not change.

Two services need a setting to sit behind a proxy, which their PRs add. Home
Assistant refuses a forwarded request unless `use_x_forwarded_for` is on and
`trusted_proxies` lists loopback. UniFi's controller serves HTTPS itself, with
a self-signed certificate, so its upstream is HTTPS, on loopback, unverified.

## The registry

### Its shape

`lib/net.nix` gains `services`. Data only, like the rest of the file, which
`builtins.toJSON` exports for `dns-top-domains`. The values are the planned
ones, and each PR confirms its service's probe path.

```nix
# The house's web UIs, each at https://<name>.<domain> through the proxy on
# its host (docs/services.md). <domain> is `services-domain` in the sops file
# of each host that serves or answers these names, and never here. A service
# joins this set in the pull request that puts it behind its proxy.
services = {
  grafana = {
    host = "core5";
    # A name in `ports`: where the service itself listens, on loopback.
    port = "grafana";
    # Segments that reach it. Tunnel peers are `segments.vpn.grants`.
    segments = [ "trusted" ];
    # What core5's probe asks for. It must answer without a login.
    probe = "/api/health";
    # The offboxPush entry that copies its state off the host, or null.
    # Grafana's is provisioned from this repo.
    backup = null;
  };
  home-assistant = {
    host = "core5";
    port = "homeAssistant";
    segments = [ "trusted" ];
    probe = "/manifest.json";
    backup = "home-assistant-backup";
  };
  unifi = {
    host = "core5";
    port = "unifiUi";
    # The controller serves TLS itself, with its own certificate.
    upstream = "https";
    segments = [ "trusted" ];
    # It administers the network itself, so no peer may hold it.
    grantable = false;
    probe = "/status";
    backup = "unifi-backup";
  };
  adguard-core4 = {
    host = "core4";
    port = "adguardWeb";
    segments = [ "trusted" ];
    probe = "/login.html";
    backup = null;
  };
  # adguard-lifeline: the same, on lifeline.
};
```

The attribute name is the label. `upstream` defaults to `"http"`, and
`grantable` to true. AdGuard is two entries because it is two UIs, each with
its own state.

Who may reach a service is half here. `segments` is, and the peers are not,
because CLAUDE.md keeps one place for what a peer may reach. That place moves.

### Tunnel grants move into lib/net.nix

gate's forward rules match an address and a port. Today each UI has a port of
its own, so a grant names one UI. Behind a proxy, every service on a host
shares that host's 443, and a rule that lets the phone reach Home Assistant on
core5 lets it reach Grafana's and UniFi's login pages too. Only the proxy can
tell them apart, by name, so it has to know which peer holds which grant, and
`grants` is a binding inside `hosts/gate/wireguard.nix` that core5's
evaluation cannot read.

Two ways out:

- **An address per service**, so gate can match each one. Every new service
  would be a new address on a Pi's interface, and so a restart of its
  `network-addresses-<iface>` unit, which removes every address on the
  interface before adding them back, that night, unattended. Preflight rates
  each one `be there`, rightly.
- **`grants` in `lib/net.nix`**, as `segments.vpn.grants` beside the peers'
  addresses, where gate and every proxy read it. gate enforces it per host,
  and the proxy per service.

**The second.** It is still the one place a peer's reach is written, which is
what CLAUDE.md's invariant protects, so the invariant's wording moves with it,
in CLAUDE.md and the README, in the grants PR (step 3).

```nix
vpn = {
  # id, subnet, gateway, prefixLength and peers as today.

  # What each peer may reach through the tunnel beyond DNS, which every peer
  # has: `ssh`, `internet`, or the name of a grantable service.
  grants = {
    forge = [
      "ssh"
      "internet"
      "grafana"
      "adguard-core4"
      "adguard-lifeline"
    ];
    phone = [ "home-assistant" ];
  };
};
```

The `adguard` grant becomes the two AdGuard services. The grants that are not
services are `segments.vpn.grantNames`, beside it, which net-assertions and
gate's rules both read. The assertion that every peer with a key has an entry
stays in `hosts/gate/wireguard.nix`, since the keys are gate's.

### What reads it

- **Unbound**, on the resolvers: the static zone, one A record per service.
- **Caddy**, on each host the registry names: one site per service there, at
  `<name>.{$SERVICES_DOMAIN}`, with its allowlist from `segments`, `grants`
  and the collector, proxying to `127.0.0.1` at its `port`.
- **The firewall** on those hosts: 443 opened on the LAN interface, and each
  service's own port absent from it, asserted.
- **gate's forward rules**: per peer, one rule for each host where it holds a
  service, `ip saddr <peer> ip daddr <host> tcp dport 443 accept`. The grants
  `wireguard.nix` accepts become `ssh`, `internet` and every grantable
  service.
- **core5's probe**: an HTTPS probe per service. The blackbox exporter cannot
  look the names up, since core5 resolves through public resolvers
  ([`hosts/core5`](../hosts/core5/default.nix)), so each probe goes to its
  host's address, with the name as the TLS server name and the `Host` header.
  Those carry the domain, so the exporter's configuration becomes a sops
  template, its build-time check run on the template's content, where the
  placeholder is only a string. The `instance` label is the host's name and a
  `service` label the service's, never the domain or an address, since every
  label leaves the house in the push
  ([`modules/alert-rules.nix`](../modules/alert-rules.nix)).
- **core5's public-name probe**: a DNS probe per service name, asked of each of
  `net.publicResolvers`, which is what every device off the fleet's resolvers
  sees. The only correct answer is NXDOMAIN or an empty answer, so any A or
  AAAA record fails it. The query names carry the domain, so they live in the
  same template, with the same labels.
- **Three alerts**, with cases in `tests/alert-rules.nix`. `ServiceDown` is a
  probe failing for 5 minutes, which covers a dead service, a dead proxy and a
  certificate the probe cannot verify. `CertificateExpiring` is under 14 days
  left. A probe failing for every service on a host that is up points at the
  proxy. `PublicNameAnswered`, critical, is public DNS answering a service's
  name on two probes in a row. Nothing in this design publishes one, so it
  means the zone was changed by someone else, and the response is revoking the
  DNS token.
- **Backups**: on the service's host, the proxy module asserts that a
  `backup` names an `offboxPush` entry there, which carries its own failure
  and heartbeat alerts ([`modules/offbox-push.nix`](../modules/offbox-push.nix)).
  So a stateful service joins the registry with its backup named or with null
  written down, and a review sees which.

### What net-assertions checks

- Each name is a DNS label: lowercase letters, digits and hyphens, at most 63
  characters. Names are unique because they are attribute names.
- `host` is a host with an `ip`. gate has none, and runs no proxy.
- `port` is a name in `ports`, and no two services on one host name the same
  one.
- `segments` names declared segments that reach the host without a gate rule
  of their own: trusted, through "trusted reaches servers", and the host's own
  segment. A service for iot or work is a gate rule, to design when one is
  wanted.
- `upstream` is `"http"` or `"https"`, and `probe` starts with `/`.
- Every grant is held by a peer with an address, and is `ssh`, `internet` or
  a service whose `grantable` is not false. A grant of `unifi` fails here,
  at evaluation.

## Access

**The phone gains Home Assistant**, through the tunnel, at the same name as at
home. The phone is DNS only because it is the device most likely to be lost,
and [home-assistant.md](home-assistant.md) leaves a grant for Home Assistant
to be "its own decision". This record makes it: granted, once Home Assistant
is behind TLS, since that doc holds plain HTTP acceptable only while nothing
outside trusted reaches the port. It buys the lights and automations from
anywhere, much of what a vendor's cloud gave before Home Assistant replaced
it. It costs this: a lost phone with the tunnel up reaches Home Assistant's
login page, and with the companion app signed in, Home Assistant itself.
Revoking is two steps: delete the phone's key and deploy gate (README, "Remote
access"), and delete the app's refresh token in the user's Home Assistant
profile.

The app takes one URL, `https://home-assistant.<domain>`, which resolves the
same at home and through the tunnel, so no home Wi-Fi network needs naming in
it. The phone's WireGuard config is made by hand, and its allowed IPs must
include core5's address.

**forge gains Grafana.** [observability.md](observability.md) deferred it
until missed, as a change to gate's firewall behind `deploy-guard` for a
convenience. The grants PR changes gate's firewall anyway, since AdGuard's
grant moves from port 3000 to 443, so Grafana costs no deploy of its own.
Striking it is one word.

**forge keeps AdGuard**, at its two new names. **No peer gets UniFi**, as
before, and now evaluation refuses one.

**Segments**: trusted, as today. servers keeps only the collector's address,
for the probe.

## Logins

**Each service keeps its own, and single sign-on is out of scope.** With TLS,
each login is encrypted to its host, which is what this record is for. Home
Assistant offers a second factor of its own, per user, with nothing added.

What single sign-on would cost now:

- Of these UIs, only Grafana speaks OpenID Connect. Home Assistant, AdGuard
  Home and UniFi do not, so for them it would be a login page in the proxy,
  ahead of the service.
- That login page breaks the companion app, which calls Home Assistant's API
  directly and cannot pass an interactive login put in front of it.
- The identity provider would be one more stateful service, with a backup and
  an upgrade path of its own, that every UI then depends on.

What would change the answer: services reached by people other than Nick, who
would then need accounts made and revoked in one place; anything reached from
beyond the tunnel; or the NAS bringing enough services that speak OpenID
Connect, as Immich does, that one login would replace several.

## The PRs, in order

Each depends on the one before, except where it says so. A change to a Pi's
firewall rates `be there`, since the Pi applies it unattended that night. The
verdicts are what preflight's rules give, and each PR quotes its own. Only
gate's PR needs `deploy-guard`.

Before step 4, Nick buys the domain, makes the token and writes both secrets
("What Nick does by hand"). `modules/sops-assertions.nix` fails evaluation
until they exist, so they are committed before the PR that declares them, or
as its first commit.

1. **`docs/services: design names, tls and one registry for the house's web
   services`.** This file, and its row in the README. No host changes:
   `routine`.
2. **`net: a services registry in lib/net.nix, with its checks`.** `services`,
   holding Grafana alone, and its assertions. Nothing reads it, so no toplevel
   changes: `routine`.
3. **`net: tunnel grants in lib/net.nix`.** `grants` moves from
   `hosts/gate/wireguard.nix` to `segments.vpn.grants`, and its checks into
   net-assertions. `adguard` stays a known grant, for port 3000, until step 11
   replaces it. CLAUDE.md, the README, network.md and the comments that name
   `grants` follow it. gate's rules render as before, which the brief shows as
   gate unchanged: `routine`. Depends only on step 2.
4. **`unbound: answer the services' names on the resolvers`.** The static
   zone on core4 and lifeline, from a sops template, `dns-top-domains`
   counting the names as local, and keys.md's row for `services-domain`. A VM
   test beside `tests/dns-metrics.nix`, with a stand-in domain: a service's
   name answers its host's address, an unknown name is NXDOMAIN, and so is the
   challenge's name at the resolver. Both
   resolvers restart Unbound that night, an hour apart: `review`. The names
   point at core5, where nothing listens on 443 yet, which is harmless.
5. **`core5: grafana behind caddy`.** The proxy module and its lego unit,
   imported on core5, with the domain and the token declared there; Grafana on
   loopback; 443 opened on core5's LAN interface and 3030 closed; the README's
   Grafana address; privacy.md's rows, and keys.md's for `services-dns-token`.
   A VM test of the proxy with a stand-in
   certificate: an allowed source reaches Grafana, any other gets a 403, and
   3030 answers on loopback alone. The first certificate is issued on core5
   that night. Firewall on core5: `be there`. If issuance fails, Caddy does not
   start, which pushes, and only Grafana's page is affected, reachable through
   the SSH tunnel meanwhile.
6. **`core5: probe each service over https, and its name in public dns`.** The
   blackbox template, the HTTPS probes and the public-name DNS probes,
   `ServiceDown`, `CertificateExpiring` and `PublicNameAnswered` with their
   cases in `tests/alert-rules.nix`, and observability.md's probes and alerts.
   Services restart on core5: `routine`.
7. **`core5: home assistant behind caddy`.** Its entry, its site, and
   `use_x_forwarded_for` with `trusted_proxies`. Home Assistant still listens
   on 8123 too, so nothing pointing there breaks. Home Assistant restarts:
   `routine`. Then Nick sets Home Assistant's URLs and the app's.
8. **`core5: home assistant on loopback alone`.** 8123 closed, and
   home-assistant.md rewritten for the new address and the end of plain HTTP.
   Firewall on core5: `be there`.
9. **`core5: unifi behind caddy`.** Its entry with `grantable = false`, its UI
   published on loopback, 8443 closed, and unifi.md. Firewall on core5: `be
   there`. It needs only step 6, so it can go ahead of steps 7 and 8, a night
   apart from either.
10. **`pis: adguard behind caddy on the resolvers`.** Both entries, the proxy
    module on core4 and lifeline with the token declared there, AdGuard's web
    UI on loopback, 443 opened and 3000 closed. `tests/dns-metrics.nix` still
    passes, since AdGuard's statistics are read on loopback. Until step 11,
    forge has no AdGuard through the tunnel, since its `adguard` grant still
    points at 3000. Firewall on both resolvers, both restarting AdGuard: `be
    there`.
11. **`gate: tunnel grants for the services`.** wireguard.nix's rule per
    granted host, the `adguard` grant replaced by the two services, `grafana`
    for forge and `home-assistant` for the phone, and every proxy's allowlist
    following. A new VM test, since none covers wireguard.nix's forward rules
    yet: the phone reaches core5's 443 and gets Home Assistant but a 403 from
    Grafana, and reaches neither resolver; forge reaches all three hosts.
    network.md's "Local name resolution is a gap" is closed in the same PR.
    `lib/net.nix` changes on both sides, so the brief says `be there`, though
    either order is safe here: gate and the proxy must each allow a peer, so
    whichever lands first opens nothing alone. gate behind `deploy-guard`.

The NAS's services join the registry when the NAS does, each behind a proxy
on the NAS. From then on a new service is an entry in `services`, a bind to
loopback, and a grant if a peer needs it.

## What Nick does by hand

- **Make the account**: a Cloudflare account for the services alone, with its
  own login, email address and second factor, kept in the password manager.
  The DDNS zone's login is not added to it as a member.
- **Buy the domain**, and put its DNS in that account with no records.
- **Make the token**: an API token owned by that account, with DNS edit on
  the zone alone.
- **Write both secrets**, before step 4, from the repo, in your own terminal.
  The domain's shape is checked before anything is written, and the token's
  read does not echo. The block has no comments, since interactive zsh runs a
  pasted `#` line as a command.

  ```bash
  read -r domain
  domain=$(printf '%s' "$domain" | tr A-Z a-z)
  if printf '%s\n' "$domain" | grep -qxE '([a-z0-9-]+\.)+[a-z]{2,}'; then
    for h in core4 lifeline core5; do
      printf '"%s"' "$domain" | sops set --value-stdin secrets/$h.yaml '["services-domain"]'
    done
  else
    echo "not a domain name; nothing written"
  fi
  read -rs token
  for h in core4 lifeline core5; do
    printf '"%s"' "$token" | sops set --value-stdin secrets/$h.yaml '["services-dns-token"]'
  done
  unset domain token
  ```

- **After step 7**, in Home Assistant's network settings, both URLs to
  `https://home-assistant.<domain>`, and in the companion app, the server's URL
  to the same, with no internal URL and no home networks. Check it at home
  before step 8.
- **Before deploying step 11**, the phone's WireGuard allowed IPs include
  core5's address, if they do not already.
- **Deploy gate** after step 11, behind `deploy-guard`.
- **Bookmarks**, as each service moves.

Nothing is installed on any device, which is the public CA's point.

## Decided

Nick's answers. Each is argued in the section it names.

1. **A public CA**, so every device that opens Home Assistant trusts it with
   nothing installed ("A public CA, chosen").
2. **A domain of its own**, not a subdomain of the DDNS zone. A token for that
   zone could also move the record peers dial, and a CNAME to another zone
   still needs a second zone ("The domain").
3. **The domain kept out of the repo**, in sops as `services-domain` ("What
   is identifying").
4. **`grants` move into `lib/net.nix`**, still the one place a peer's reach is
   written. CLAUDE.md's invariant and the README move with them, in the grants
   PR ("Tunnel grants move into lib/net.nix").
5. **The phone gets Home Assistant, and forge gets Grafana**, through the
   tunnel ("Access").
6. **The domain's DNS in a Cloudflare account of its own**, with its own
   login and a token that account owns ("The domain", "The token").

## What would reopen this

- **A service someone must reach from outside the tunnel.** That is a port on
  gate's `wan`, or a third party in front of the house, and a design of its
  own.
- **Who opens these UIs.** The public CA was chosen for every device that
  opens Home Assistant ("Decided", 1). If that comes down to forge and one
  phone, the private CA is cheaper.
- **The domain going public.** It could then be in `lib/net.nix`, lego would
  become NixOS's `security.acme`, and the four splices plain evaluation.
- **Caddy with DNS providers in a cache**, or built in. lego's unit would then
  fold into Caddy.
- **The NAS**, if it brings more services that speak OpenID Connect than
  logins worth keeping apart ("Logins").
