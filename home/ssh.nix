# SSH agent management for interactive dev hosts.
#
# Why keychain and not a systemd user service: WSL doesn't start a per-user
# systemd instance (logind creates no session, so /run/user/$UID and the user
# bus never exist), which means `services.ssh-agent` / a `systemd --user` unit
# can't run there. keychain is the portable alternative — it starts a single
# ssh-agent, reuses it across every shell and login, and prompts for each
# key's passphrase once per boot. The bash/zsh integrations source keychain's
# environment on startup so SSH_AUTH_SOCK is always wired up.
#
# forge does have a user systemd, but nothing there starts an agent either
# (Plasma does not, and programs.ssh.startAgent is off), so keychain serves it
# the same way and one mechanism covers every Linux dev host.
#
# Linux-only: macOS has its native launchd ssh-agent + Keychain, so this is
# scoped out there (mirrors the isDarwin split in git.nix). The fleet's host
# entries below are Linux-only too, for a different reason: the Linux dev
# hosts, WSL and forge, are the admin machines in lib/ssh-keys.nix, and the work
# Mac is deliberately not one.
{
  config,
  pkgs,
  lib,
  net,
  ...
}:
let
  # The servers have one address each in lib/net.nix. gate has none there,
  # holding .1 in every segment, and admin machines sit on trusted, so they
  # reach it at that segment's gateway.
  #
  # Away from home, over WireGuard, gate is `gate-vpn` at its tunnel address
  # instead. 192.168.10.1 is the gateway of countless other networks, so
  # routing it into the tunnel would capture a hotel's own router; see
  # hosts/forge/vpn.nix. The servers keep one name, since their /32s route
  # through the tunnel without colliding.
  fleet =
    lib.mapAttrs (_name: host: { address = host.ip; }) (
      lib.filterAttrs (_name: host: host ? ip) net.hosts
    )
    // {
      gate.address = net.segments.trusted.gateway;
      gate-vpn = {
        address = net.segments.vpn.gateway;
        user = "gate";
        hostKeyAlias = net.segments.trusted.gateway;
      };
    };

  # ssh to the fleet for Claude Code. Its sandbox has no route to the network
  # that plain ssh will take, so home/claude.nix excludes this one command from
  # the sandbox, and it runs with Nick's full access. What keeps that safe is
  # that nothing about the local side is an argument: the host must be one of
  # the names above, the options are fixed, and ProxyCommand and LocalCommand,
  # which would run an arbitrary local command, are off. Everything after the
  # host goes to the remote side, where sudo wants a password.
  #
  # keychain's environment file names the agent, because the process Claude
  # Code runs under never sourced a login shell. After a reboot the agent is
  # empty until `ssh-add`, and BatchMode turns that into a refusal rather than
  # a prompt that would hang. That file is sourced, so its path comes from
  # nothing a caller can set: the home directory is fixed here and the
  # hostname read from the kernel, not $HOME and $HOSTNAME. What bash and the
  # loader act on before the first line (BASH_ENV, LD_PRELOAD) is beyond this
  # script; that rests on Claude Code not taking `VAR=x fleet-ssh` for
  # fleet-ssh.
  #
  # -F reads the config this file writes and skips the system's. Debian's
  # /etc/ssh/ssh_config, on WSL, sets GSSAPIAuthentication, which nixpkgs'
  # OpenSSH does not know, so every call warned.
  fleetSsh = pkgs.writeShellApplication {
    name = "fleet-ssh";
    runtimeInputs = [ pkgs.openssh ];
    text = ''
      hosts="${lib.concatStringsSep " " (builtins.attrNames fleet)}"
      if [ "$#" -lt 2 ]; then
        echo "usage: fleet-ssh <host> <command...>   hosts: $hosts" >&2
        exit 64
      fi
      host=$1
      shift
      case "$host" in
        ${lib.concatStringsSep "|" (builtins.attrNames fleet)}) ;;
        *)
          echo "fleet-ssh: $host is not a fleet host   hosts: $hosts" >&2
          exit 64
          ;;
      esac
      agent="${config.home.homeDirectory}/.keychain/$(</proc/sys/kernel/hostname)-sh"
      if [ -r "$agent" ]; then
        # shellcheck disable=SC1090
        . "$agent"
      fi
      exec ssh \
        -F "${config.home.homeDirectory}/.ssh/config" \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        -o ProxyCommand=none \
        -o PermitLocalCommand=no \
        -o ClearAllForwardings=yes \
        -- "$host" "$@"
    '';
  };

  # Every fleet host's `host-status` (modules/host-status.nix) at once, with
  # each running revision compared against main on GitHub. gate-vpn is the same
  # host as gate, so it is asked only when named, which is the way to reach
  # gate from away from home.
  #
  # Calls fleet-ssh, so inside Claude Code's sandbox it reaches nothing. Claude
  # runs `fleet-ssh <host> host-status` per host instead.
  fleetStatus = pkgs.writeShellApplication {
    name = "fleet-status";
    runtimeInputs = [
      fleetSsh
      pkgs.coreutils
      pkgs.curl
      pkgs.gawk
      pkgs.gnused
      pkgs.jq
    ];
    text = ''
      known="${lib.concatStringsSep " " (builtins.attrNames fleet)}"
      if [ "$#" -gt 0 ]; then
        hosts="$*"
      else
        hosts="${lib.concatStringsSep " " (lib.remove "gate-vpn" (builtins.attrNames fleet))}"
      fi
      for host in $hosts; do
        case " $known " in
          *" $host "*) ;;
          *)
            echo "fleet-status: $host is not a fleet host   hosts: $known" >&2
            exit 64
            ;;
        esac
      done

      out=$(mktemp -d)
      trap 'rm -rf "$out"' EXIT

      # In parallel, so one host that is down costs its own timeout rather
      # than adding it to everyone else's. ConnectTimeout in fleet-ssh covers
      # only connecting; this covers a host that accepts the session and then
      # hangs, such as one whose root device is failing.
      for host in $hosts; do
        timeout 30 fleet-ssh "$host" host-status >"$out/$host" 2>"$out/$host.err" &
      done
      wait

      # Where a revision stands against main, from GitHub's public API, which
      # needs no token. In compare/<rev>...main, "ahead" means main is ahead,
      # so the host is behind, and "behind" means the host runs commits main
      # does not have yet. Anything that is not a full commit hash is not
      # asked about: a dirty tree's revision, or "unknown".
      behind() {
        local rev=$1 code status ahead behind
        if ! [[ $rev =~ ^[0-9a-f]{40}$ ]]; then
          echo "''${rev:0:12}"
          return
        fi
        code=$(curl -sS --max-time 15 -o "$out/compare.json" -w '%{http_code}' \
          "https://api.github.com/repos/nnorx/nix-config/compare/$rev...main") || code=000
        case $code in
          200) ;;
          404) echo "''${rev:0:7} not on GitHub" && return ;;
          403 | 429) echo "''${rev:0:7} (rate limited)" && return ;;
          *) echo "''${rev:0:7} (main unknown)" && return ;;
        esac
        read -r status ahead behind < <(jq -r '"\(.status) \(.ahead_by) \(.behind_by)"' "$out/compare.json")
        case $status in
          identical) echo "''${rev:0:7} main" ;;
          ahead) echo "''${rev:0:7} $ahead behind" ;;
          behind) echo "''${rev:0:7} $behind ahead" ;;
          *) echo "''${rev:0:7} $behind ahead, $ahead behind" ;;
        esac
      }

      # Prints one fact from a host's output, by key.
      get() { awk -F '\t' -v k="$2" '$1 == k { print $2 }' "$out/$1"; }

      row='%-9s %-26s %-16s %-24s %s\n'
      # shellcheck disable=SC2059
      printf "$row" HOST REVISION ROOT UPGRADE FAILED
      for host in $hosts; do
        if [ ! -s "$out/$host" ]; then
          # The last line of ssh's complaint, which names the cause where the
          # first can be a warning banner, with any address masked, since this
          # output may land in a transcript.
          why=$(tail -n 1 "$out/$host.err" | sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<addr>/g')
          if ! [ -s "$out/$host.err" ] && ! [ -s "$out/$host" ]; then
            why="no answer within 30 seconds"
          fi
          case $why in
            *"command not found"*) why="no host-status yet; it arrives with this host's next deploy" ;;
            *"Permission denied"*) why="unreachable: $why (agent empty? ssh-add ~/.ssh/id_ed25519_pis)" ;;
            *) why="unreachable: ''${why:-no output}" ;;
          esac
          printf '%-9s %s\n' "$host" "$why"
          continue
        fi
        # shellcheck disable=SC2059
        printf "$row" "$host" \
          "$(behind "$(get "$host" revision)")" \
          "$(get "$host" root)" \
          "$(get "$host" upgrade)" \
          "$(get "$host" failed)"
      done
    '';
  };
in
{
  # Linux only, like the rest of this file: the Mac is not an admin machine.
  home.packages = lib.optionals pkgs.stdenv.isLinux [
    fleetSsh
    fleetStatus
  ];

  # `ssh core4`, `ssh gate` and so on, from any admin machine. The login user
  # is the hostname, as hosts/common makes it.
  #
  # IdentitiesOnly, because otherwise ssh offers every key the agent holds
  # before the one named here, and the hosts allow three attempts
  # (modules/ssh.nix). Another key or two loaded first is a refused login.
  #
  # Home Manager owns ~/.ssh/config from here on. Hosts it does not generate go
  # in ~/.ssh/config.local, which is read first, so an entry there for a fleet
  # host would win over the one generated here.
  programs.ssh = lib.mkIf pkgs.stdenv.isLinux {
    enable = true;
    # Home Manager's legacy defaults are deprecated, and none are wanted.
    enableDefaultConfig = false;
    includes = [ "config.local" ];
    #
    # `gate-vpn` checks gate's host key under the home address, which is where
    # every admin machine already has it recorded, so trust carries over with
    # nothing to migrate. Without the alias the tunnel address is a new name:
    # ssh asks again interactively, noting the key is known elsewhere, and
    # under BatchMode it refuses outright.
    settings = lib.mapAttrs (
      name: host:
      {
        HostName = host.address;
        User = host.user or name;
        IdentityFile = "~/.ssh/id_ed25519_pis";
        IdentitiesOnly = true;
      }
      // lib.optionalAttrs (host ? hostKeyAlias) { HostKeyAlias = host.hostKeyAlias; }
    ) fleet;
  };

  programs.keychain = lib.mkIf pkgs.stdenv.isLinux {
    enable = true;
    # keychain 2.9.0+ auto-detects the ssh agent, so `agents` is deprecated
    # and omitted. Key names resolve relative to ~/.ssh.
    #
    # id_ed25519_pis is listed because it has a passphrase: IdentityFile only
    # says which key to offer, not who signs with it, so without an agent
    # holding it every connection to a Pi or to gate prompts, and each new
    # shell starts with an empty agent.
    keys = [
      "id_ed25519_pis"
    ];

    # --noask: never prompt for a passphrase at shell startup. Without it,
    # every new shell asks for any listed key the agent does not already hold,
    # which is a prompt on every terminal, including on days no fleet host is
    # touched. Declining does not help — keychain simply asks again next time.
    #
    # Listing a key the machine does not have costs a warning on every shell,
    # so only keys every Linux dev host carries belong here.
    #
    # The keys stay declared, so this makes loading opt-in rather than removing
    # them: run `ssh-add ~/.ssh/id_ed25519_pis` once after a boot, and keychain
    # keeps that agent alive across every subsequent shell and login. Which is
    # the whole point of listing the Pi key: one prompt per boot covers every
    # host in the fleet, instead of one per connection.
    extraFlags = [
      "--quiet"
      "--noask"
    ];
  };
}
