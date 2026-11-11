# The night shift's entry point. The dispatcher is TypeScript (src/main.ts
# says what it does); this keeps the parts a shell does best. A run holds a
# lock and, however it ends, lets the machine sleep after it, and on a Mac
# gets the deadline that systemd gives forge's. Built with
# writeShellApplication, which adds the shebang, errexit, nounset and pipefail.

ts=${NIGHT_SHIFT_TS:?}
state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/night-shift
# For setup commands and the key command, which must not take whatever bash
# a config's PATH puts first.
export NIGHT_SHIFT_BASH=$BASH

case ${1-} in
  run)
    mkdir -p "$state_dir"
    # One run at a time, whether the timer's or Nick's.
    exec 9>"$state_dir/lock"
    flock -n 9 || {
      echo "night-shift: a run is already going" >&2
      exit 0
    }
    # However the run ends: one that cannot reach Linear ends early, and a
    # machine taken off AC and offline must still be let sleep.
    trap 'node "$ts" _awake 9>&-' EXIT
    # Without the lock's descriptor, which claude's daemon or a repository's
    # setup would otherwise inherit and hold for as long as it lives. Not
    # exec, so this shell keeps the lock and the trap.
    node "$ts" run 9>&-
    ;;
  # launchd's entry on a Mac (home/night-shift.nix), for what systemd gives
  # forge's unit: an hour's deadline, as TimeoutStartSec, then _after with how
  # the run ended, as ExecStopPost has it. At the deadline timeout ends the
  # run's whole process group, its setup commands with it, as stopping the
  # unit ends its cgroup; claude's daemon, in a group of its own, stays. Not
  # set up yet, with no config, it does nothing, and that is no failure.
  _tick)
    if [[ -n ${NIGHT_SHIFT_LOG:-} && -f $NIGHT_SHIFT_LOG ]] && (($(stat -c %s "$NIGHT_SHIFT_LOG") > 5000000)); then
      mv "$NIGHT_SHIFT_LOG" "$NIGHT_SHIFT_LOG.old"
    fi
    [[ ${NIGHT_SHIFT_MODE:-forge} == forge || -e ${NIGHT_SHIFT_CONFIG:-} ]] || exit 0
    echo "night-shift: run at $(date -u +%FT%TZ)"
    rc=0
    timeout --kill-after=60 3600 "$BASH" -euo pipefail "$0" run </dev/null || rc=$?
    case $rc in
      0) result=success ;;
      124 | 137) result=timeout ;;
      *) result=exit-code ;;
    esac
    SERVICE_RESULT=$result EXIT_STATUS=$rc exec node "$ts" _after
    ;;
  *) exec node "$ts" "$@" ;;
esac
