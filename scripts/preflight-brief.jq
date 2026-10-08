# The brief scripts/preflight.sh prints: which configs a change touches, what
# kind of change each host gets, and a verdict on whether merging needs Nick at
# hand that night. Merging deploys the hosts that upgrade themselves, so the
# verdict is about those; for the rest the brief says how to deploy.
#
# Inputs, from preflight.sh as one object on stdin, since a side's facts
# outgrow what a single command-line argument may hold:
#   $head, $base  scripts/preflight-eval.nix's output for the change and its base
#   $ok           false when the base did not evaluate, which makes it all unknown
#   $files        the paths the change touches
#   $versions     per changed host, {base, head}: package name -> its versions,
#                 read from each side's derivation closure
#   $rev          the base, as printed in headings
# and, as --arg, $format: json, text or md.
#
# Findings have a level. "be there" is something that happens unattended on a
# host that upgrades itself and that, if it goes wrong, needs hands on it:
# merge when you can be at home that night. "review" deserves a careful read but
# recovers by itself or waits for a manual deploy. "note" is how to deploy.
# Comparing with the base, not with what a host runs, misses one case: a host
# that skipped an earlier reboot still reboots tonight even when this change
# leaves its kernel alone.

. as {$head, $base, $ok, $files, $versions, $rev}
|

def levels: ["be there", "review", "note"];
def rank: . as $l | levels | index($l);

def finding($level; $area; $text): {level: $level, area: $area, text: $text};

# Keys whose values differ between two objects, and keys only one side has.
def diffmap($b; $h):
  {
    changed: [$b | keys[] | select(. as $k | $h | has($k)) | select($b[.] != $h[.])],
    added: [$h | keys[] | select(. as $k | $b | has($k) | not)],
    removed: [$b | keys[] | select(. as $k | $h | has($k) | not)]
  };

def all_of: .changed + .added + .removed;

# "a", "a and b", "a, b and c".
def prose: if length > 1 then (.[:-1] | join(", ")) + " and " + .[-1] else join("") end;

# "core4 takes", "core4, lifeline take": names as the subject of a verb.
def subject($one; $many): join(", ") + " " + (if length == 1 then $one else $many end);

# "a, b, c" with at most $n names, then a count of the rest.
def names($n):
  if length > $n then (.[:$n] | join(", ")) + " (+\(length - $n) more)" else join(", ") end;

def state($h; $b):
  if $ok | not then "unknown"
  elif $h == null then "removed"
  elif $b == null then "new"
  elif $h == $b then "unchanged"
  else "changed" end;

def network_unit:
  test("^(network-addresses-|network-setup|network-link-|systemd-networkd|wireguard-|wg-quick-|kea-|dhcpcd|NetworkManager)");

def svc: sub("\\.service$"; "");

# What switch-to-configuration does with each unit that changed, appeared or
# went away. A changed service restarts if it is running, unless it reloads or
# opted out. A template (name@.service) is never started itself, so it is
# listed with the other units.
def actions($h; $u):
  def service: endswith(".service") and (endswith("@.service") | not);
  ($u.changed | map(select(service) | svc)) as $svc
  | def opt($s): $h.services[$s] // {restart: true, reload: false};
  {
    restarts: [$svc[] | select(opt(.).restart and (opt(.).reload | not))],
    reloads: [$svc[] | select(opt(.).reload)],
    "not restarted": [$svc[] | select((opt(.).restart | not) and (opt(.).reload | not))],
    starts: [$u.added[] | select(service) | svc],
    stops: [$u.removed[] | select(service) | svc],
    "other units": [$u | all_of | .[] | select(service | not)]
  };

# A package moved when a version left the closure and another arrived. A build
# closure holds bootstrap copies of the basics (an old grep, an old sed) beside
# the real ones, and a new dependency brings its own, so a version that only
# appears, or only goes, is not an upgrade and is left out. The packages a host
# installs come first.
def versions($name; $h):
  ($versions[$name] // null) as $v
  | if $v == null then []
    else
      ($h.packages + ["linux", "systemd", "glibc", "openssl", "openssh", "nix", "sudo"]) as $prio
      # Bootstrap stages and compiler wrappers move with every toolchain bump
      # and run on no host.
      | [$v.base | keys[] | select(test("bootstrap|-wrapper$") | not) | select(. as $k | $v.head | has($k))
          | {name: ., from: ($v.base[.] - $v.head[.]), to: ($v.head[.] - $v.base[.])}
          | select(.from != [] and .to != [])]
      | ([.[] | select(.name as $k | any($prio[]; . == $k))] + [.[] | select(.name as $k | all($prio[]; . != $k))])
      | map("\(.name) \(.from | join("/")) → \(.to | join("/"))")
    end;

def host_brief($name; $b; $h):
  $b.autoUpgrade as $auto
  | $h.deployGuard as $guard
  | (if $guard then ", behind deploy-guard" else "" end) as $guarded
  | diffmap($b.units; $h.units) as $u
  # /etc/systemd/system is one entry holding every unit, already compared
  # unit by unit.
  | (diffmap($b.etc; $h.etc) | all_of | map(select(. != "systemd/system" and . != "systemd/user"))) as $etc
  | [$b.reboot | keys[] | select($b.reboot[.] != $h.reboot[.])] as $rb
  | [$b.boot | keys[] | select($b.boot[.] != $h.boot[.])] as $bp
  | ($auto and $b.allowReboot and ($rb | length > 0)) as $reboots
  | ($u | all_of) as $touched
  | ([$touched[] | select(network_unit)] + [$etc[] | select(startswith("systemd/network/"))]) as $net
  | diffmap($b.users; $h.users) as $users
  # Keys are compared by content, through users: under another nixpkgs the
  # same authorized_keys text lands at a new path.
  | ([$touched[] | select(. == "sshd.service" or . == "sshd.socket") | "sshd"]
    + [$etc[] | select(. == "ssh/sshd_config") | "/etc/\(.)"]
    + [$users.removed[] | "\(.) removed, so deleted on activation"]
    + [$users.changed[] | "\(.)'s keys or groups"]) as $access
  | ([$rb[] | {
        kernel: (if $b.kernelVersion != $h.kernelVersion
          then "kernel \($b.kernelVersion) → \($h.kernelVersion)"
          else "kernel \($h.kernelVersion), rebuilt" end),
        initrd: "initrd",
        modules: "kernel modules"
      }[.]] | prose) as $what
  | {
      auto: $auto,
      kernelChanged: any($rb[]; . == "kernel"),
      touched: $touched,
      findings: [
        if $rb == [] then empty
        elif $reboots then finding("be there"; "reboot";
          "Reboots tonight, unattended, for the \($what). It upgrades at \($b.upgradeAt) and reboots only between \($b.rebootWindow.lower) and \($b.rebootWindow.upper).")
        elif $auto then finding("review"; "reboot";
          "Runs the new \($what) only from its next reboot, since it never reboots itself.")
        else finding("note"; "reboot"; "The \($what) change takes a reboot: deploy with nrb\($guarded), then reboot.")
        end,

        if $bp == [] then empty
        else ($bp | map({loader: "bootloader", params: "kernel parameters", firmware: "firmware"}[.]) | join(", ")) as $parts
          | if $auto then finding("be there"; "boot";
              "Boot path changes (\($parts)). "
              + if $reboots then "Tonight's unattended reboot is its first test."
                else "Tonight's switch installs it, and whatever reboot comes next, a power cut included, is its first test." end)
            else finding("review"; "boot"; "Boot path changes (\($parts)). Its first test is the reboot after deploying\($guarded).")
            end
        end,

        if $net == [] then empty
        elif $auto then finding("be there"; "network";
          "Networking changes on a host that applies them unattended: \($net | names(6)). A switch can drop the link it runs over.")
        else finding("review"; "network";
          "Networking changes: \($net | names(6)). If the deploy runs over this interface, use nrb and a reboot\($guarded), not nrs.")
        end,

        ([$u.added[] | select(startswith("network-addresses-")) | svc] as $na
          | if $na == [] then empty
            else finding(if $auto then "be there" else "review" end; "network";
              "switch does not start \($na | join(", ")): the interface stays down until the next reboot.")
            end),

        if $access == [] then empty
        else finding(if $auto then "be there" else "review" end; "access";
          "Who can log in, and how, changes: \($access | names(6)). A mistake here locks you out of the host.")
        end,

        if $users.added == [] then empty
        else finding("review"; "access"; "New login: \($users.added | join(", ")).")
        end,

        ([$touched[] | select(. == "firewall.service" or . == "nftables.service")] as $fw
          | if $fw == [] then empty
            elif $guard then finding("review"; "firewall"; "Firewall rules change (\($fw | join(", "))). Deploy them behind deploy-guard.")
            elif $auto then finding("review"; "firewall";
              "Firewall rules change (\($fw | join(", "))), applied tonight. Check SSH is still allowed on the interface you reach it over.")
            else finding("note"; "firewall"; "Firewall rules change (\($fw | join(", "))).")
            end),

        if $b.autoUpgrade != $h.autoUpgrade then
          finding("review"; "upgrade"; if $h.autoUpgrade then "Starts upgrading itself from main." else "Stops upgrading itself, once tonight's run has applied this." end)
        elif $auto and any($touched[]; startswith("nixos-upgrade.")) then
          finding("review"; "upgrade"; "The nightly upgrade itself changes. If the new one fails, every later fix needs a deploy by hand.")
        else empty end
      ],
      actions: actions($h; $u),
      etc: $etc,
      versions: versions($name; $h)
    };

# Across hosts: what no single host's findings show.
def plan_findings($hosts):
  [$hosts | to_entries[] | select(.value.auto)] as $auto
  | [
      ([$auto[] | select(any(.value.touched[]; . == "unbound.service" or . == "adguardhome.service")) | .key] as $dns
        | if ($dns | length) < 2 then empty
          else finding("review"; "dns";
            "Both resolvers take this change tonight (\($dns | join(", "))), an hour apart. If it breaks resolution, the house has no DNS until one is fixed.")
          end),

      ([$auto[] | select(.value.kernelChanged) | .key] as $k
        | if $k == [] then empty
          else finding("review"; "cache";
            "Merge early in the day. A Pi kernel that cache.yml has to build takes 2 to 5 hours, and an upgrade that runs before it finishes fails (\($k | join(", "))).")
          end),

      # Addressing in lib/net.nix that reaches hosts on both sides lands in two
      # halves, the first tonight, so the Pis can end up ahead of gate.
      ([$hosts | to_entries[] | select(.value.auto | not) | .key] as $manual
        | ([$auto[] | .key | $base.hosts[.].upgradeAt] | min) as $first
        | if $manual == [] or $auto == [] or all($files[]; . != "lib/net.nix") then empty
          else
            finding("be there"; "addressing";
              "lib/net.nix changes on both sides: \($auto | map(.key) | subject("takes"; "take")) it tonight, first at \($first), and \($manual | join(", ")) only when deployed by hand. Deploy those first, or the hosts disagree until you do.")
          end),

      ([$files[] | capture("^secrets/(?<h>[^/]+)\\.yaml$").h] as $s
        | if $s == [] then empty
          else finding("note"; "secrets"; "Secrets change for \($s | join(", ")). Evaluation cannot see inside them, so check they decrypt on the host.")
          end)
    ];

def model:
  ([($head.hosts + $base.hosts) | keys[] | . as $k
    | {name: $k, kind: "host", state: state($head.hosts[$k].drv; $base.hosts[$k].drv),
       deploy: (if ($ok | not) then "?" elif $base.hosts[$k] == null then "-"
                elif $base.hosts[$k].autoUpgrade then "auto" else "manual" end)}]
   + [($head.homes + $base.homes) | keys[] | . as $k
    | {name: $k, kind: "home", state: state($head.homes[$k]; $base.homes[$k]), deploy: "-"}]) as $configs
  | (if $ok then
      [$configs[] | select(.kind == "host" and .state == "changed") | .name] as $changed
      | reduce $changed[] as $k ({}; .[$k] = host_brief($k; $base.hosts[$k]; $head.hosts[$k]))
    else {} end) as $hosts
  | (if $ok then plan_findings($hosts) else [] end) as $plan
  | ([$hosts | to_entries[] | .key as $k | .value.findings[] | . + {host: $k}] + $plan) as $all
  | ([$configs[] | select(.kind == "host" and .deploy == "auto" and .state != "unchanged") | .name]) as $tonight
  | {
      base: $rev,
      configs: $configs,
      hosts: ($hosts | map_values(del(.touched, .auto, .kernelChanged))),
      plan: $plan,
      verdict: (
        if $ok | not then
          {level: "unknown", text: "The base did not evaluate, so what this changes is unknown."}
        elif any($all[]; .level == "be there") then
          {level: "be there", text: "Merge when you can be at hand tonight: "
            + ([$all[] | select(.level == "be there")] | group_by(.host)
                | map(if .[0].host then "\(.[0].host) (\(map(.area) | unique | join(", ")))" else map(.area) | unique | join(", ") end)
                | join("; "))
            + ". docs/recovery.md has the way back."}
        elif $tonight == [] then
          if any($all[]; .level == "review")
          then {level: "review", text: "Merging changes no host that upgrades itself. The review lines are for deploying by hand."}
          else {level: "routine", text: "Merging changes no host that upgrades itself."} end
        elif any($all[]; .level == "review") then
          {level: "review", text: "\($tonight | subject("takes"; "take")) this tonight. Nothing needs you at hand, but read the review lines first."}
        else
          {level: "routine", text: "\($tonight | subject("takes"; "take")) this tonight, with no reboot and no boot, network or access change."}
        end)
    };

def detail_lines($b):
  ($b.findings | sort_by(.level | rank)[] | "\(.level): \(.text)"),
  ($b.actions | to_entries[] | select(.value != []) | "\(.key): \(.value | names(12))"),
  (if $b.etc == [] then empty else "/etc: \($b.etc | names(8))" end),
  (if $b.versions == [] then empty else "versions: \($b.versions | names(8))" end);

def render_text:
  [ (.configs | ["NAME", "KIND", "STATE", "DEPLOY"], (.[] | [.name, .kind, .state, .deploy]))
      | "\(.[0])\(" " * (15 - (.[0] | length)))\(.[1])\(" " * (6 - (.[1] | length)))\(.[2])\(" " * (11 - (.[2] | length)))\(.[3])" ]
  + (.hosts | to_entries | map(
      ["", "\(.key)", (detail_lines(.value) | "  \(.)")]) | flatten)
  + (if .plan == [] then [] else ["", "across hosts", (.plan[] | "  \(.level): \(.text)")] end)
  + ["", "Verdict: \(.verdict.level). \(.verdict.text)"]
  | join("\n");

# The verdict leads on a page, which is read from the top, and closes in a
# terminal, where the last lines are the ones in view.
def render_md:
  [ "### What this changes, against \(.base)", "",
    "**Verdict: \(.verdict.level).** \(.verdict.text)", "",
    "| Config | Kind | State | Deploy |", "|---|---|---|---|",
    (.configs[] | "| \(.name) | \(.kind) | \(.state) | \(.deploy) |") ]
  + (.hosts | to_entries | map(["", "**\(.key)**", "", (detail_lines(.value) | "- \(.)")]) | flatten)
  + (if .plan == [] then [] else ["", "**Across hosts**", "", (.plan[] | "- \(.level): \(.text)")] end)
  | join("\n");

model
| if $format == "json" then .
  elif $format == "md" then render_md
  else render_text end
