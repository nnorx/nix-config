# The tools fleet-deploy reaches the world through, stood in for by one script:
# the first argument names the tool. Each call is logged to $FD/log, and the
# case's files under $FD say how to answer. tests/fleet-deploy/run.sh has the
# cases.
#
#   $FD/main                    the commit the hosts' upgrade lands on
#   $FD/hosts.json, brief.json  what `nix eval` and preflight answer
#   $FD/preflight-fails         preflight fails, leaving an empty brief
#   $FD/now                     the time `date` tells
#   $FD/<host>/<fact>           the host's status: revision, next-boot,
#                               staged, hold, failed
#   $FD/<host>/kernel           its upgrade stages a kernel, not a switch
#   $FD/<host>/self-reboots     and then reboots by itself, as in the window
#   $FD/<host>/upgrade-fails    its upgrade fails
#   $FD/<host>/upgrade-lands    its upgrade lands here instead of on main
#   $FD/<host>/fails-during     a unit that fails once main is running
#   $FD/<host>/reboot-lost      a reboot request that never reaches it
#   $FD/<host>/down             how many more status calls it is down for
#   $FD/misses-<hash>           how many more times the cache says 404
#   $FD/run                     cache.yml's run: "status conclusion", none,
#                               or error for a rate-limited answer

tool=$1
shift
printf '%s %s\n' "$tool" "$*" >>"$FD/log"

host_status() {
  local h=$FD/$1
  printf 'revision\t%s\n' "$(<"$h/revision")"
  printf 'root\t/dev/stub\n'
  printf 'failed\t%s\n' "$(<"$h/failed")"
  printf 'upgrade\tsuccess\n'
  printf 'next-boot\t%s\n' "$(<"$h/next-boot")"
  printf 'staged\t%s\n' "$(<"$h/staged")"
  printf 'hold\t%s\n' "$(<"$h/hold")"
}

# Main is running: whatever fails under it now has.
running_main() {
  local h=$FD/$1
  [[ -e $h/fails-during ]] || return 0
  if [[ $(<"$h/failed") == none ]]; then
    cp "$h/fails-during" "$h/failed"
  else
    echo "$(<"$h/failed") $(<"$h/fails-during")" >"$h/failed"
  fi
}

case $tool in
  sleep) ;;

  ssh-add) ;;

  date) cat "$FD/now" ;;

  ssh)
    # Without -n, real ssh reads stdin, the answers meant for the prompts.
    [[ " $* " == *" -n "* ]] || cat >/dev/null
    # ... -- deploy@<host> <verb>
    target=${*: -2:1}
    verb=${*: -1}
    host=${target#deploy@}
    h=$FD/$host
    if [[ -e $h/down ]]; then
      down=$(<"$h/down")
      if ((down > 0)); then
        echo $((down - 1)) >"$h/down"
        if ((down == 1)); then
          # Back up, in what was staged.
          cp "$h/next-boot" "$h/revision"
          echo no >"$h/staged"
          running_main "$host"
        fi
        exit 255
      fi
    fi
    case $verb in
      status) host_status "$host" ;;
      upgrade)
        if [[ -e $h/upgrade-fails ]]; then
          echo "stand-in upgrade failed" >&2
          exit 1
        fi
        lands=$(<"$FD/main")
        [[ ! -e $h/upgrade-lands ]] || lands=$(<"$h/upgrade-lands")
        if [[ -e $h/kernel ]]; then
          echo "$lands" >"$h/next-boot"
          echo yes >"$h/staged"
        else
          echo "$lands" >"$h/revision"
          echo "$lands" >"$h/next-boot"
          running_main "$host"
        fi
        host_status "$host"
        if [[ -e $h/self-reboots ]]; then echo 2 >"$h/down"; fi
        ;;
      reboot)
        # The session closes before the agent answers.
        [[ -e $h/reboot-lost ]] || echo 2 >"$h/down"
        exit 255
        ;;
      hold | release)
        if [[ $verb == hold ]]; then echo yes >"$h/hold"; else echo no >"$h/hold"; fi
        printf 'hold\t%s\n' "$(<"$h/hold")"
        ;;
      *) exit 64 ;;
    esac
    ;;

  nix)
    case $1 in
      eval) cat "$FD/hosts.json" ;;
      run)
        # nix run .#preflight -- --base <rev> --head <rev> --flake-check skip --json <file>
        if [[ -e $FD/preflight-fails ]]; then
          : >"${*: -1}"
          exit 1
        fi
        echo "stand-in preflight"
        cp "$FD/brief.json" "${*: -1}"
        ;;
      *) exit 1 ;;
    esac
    ;;

  curl)
    url=${*: -1}
    case $url in
      *.narinfo)
        hash=${url##*/}
        hash=${hash%.narinfo}
        misses=0
        [[ ! -e $FD/misses-$hash ]] || misses=$(<"$FD/misses-$hash")
        if ((misses > 0)); then
          echo $((misses - 1)) >"$FD/misses-$hash"
          printf 404
        else
          printf 200
        fi
        ;;
      *api.github.com*)
        read -r status conclusion <"$FD/run"
        case $status in
          none) echo '{"total_count": 0, "workflow_runs": []}' ;;
          error) echo '{"message": "API rate limit exceeded"}' ;;
          *)
            jq -n --arg s "$status" --arg c "$conclusion" \
              '{workflow_runs: [{status: $s, conclusion: (if $c == "-" then null else $c end)}]}'
            ;;
        esac
        ;;
      *) exit 1 ;;
    esac
    ;;

  *) exit 1 ;;
esac
