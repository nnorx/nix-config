# secret-set and secret-check (home/secret.nix): a value into or out of a
# host's sops file without it reaching the screen, scrollback or history.
#
#   secret-set <host|file> <key>           asks twice, or takes stdin as is
#   secret-check <host|file> <key>...      set or missing, length, shape
#   ... | secret-check <host|file> <key>   equal to stdin or not
#
# <host> means secrets/<host>.yaml in this checkout. <key> is a top-level name
# or a sops index such as '["a"]["b"]'.

# set or check, from the name it was run by.
mode=${0##*-}

die() {
  printf 'secret-%s: %s\n' "$mode" "$*" >&2
  exit 1
}

(($# >= 2)) || die "usage: secret-$mode <host|file> <key>"
file=$1
shift
if [[ ! -f $file ]]; then
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "run it from a nix-config checkout, or name the file"
  file=$root/secrets/$file.yaml
  [[ -f $file ]] || die "no $file"
fi

index() {
  if [[ $1 == \[* ]]; then printf '%s' "$1"; else jq -nc --arg k "$1" '[$k]'; fi
}

# Sets `got` to the value exactly: $(...) alone drops trailing newlines.
fetch() {
  got=$(sops decrypt --extract "$(index "$1")" "$file" 2>/dev/null && printf x) || return 1
  got=${got%x}
}

shape() {
  local v=$1 note=""
  [[ $v == *$'\n' ]] && note=", ends with a newline"
  v=${v%$'\n'}
  if [[ $v == *$'\n'* ]]; then echo "several lines$note"
  elif [[ $v =~ ^[0-9a-f]+$ ]]; then echo "hex$note"
  elif [[ $v =~ ^[A-Za-z0-9_-]+$ ]]; then echo "letters, digits, - and _$note"
  elif [[ $v =~ ^[A-Za-z0-9+/]+=*$ ]]; then echo "base64$note"
  else echo "other characters$note"; fi
}

if [[ $mode == set ]]; then
  (($# == 1)) || die "usage: secret-set <host|file> <key>"
  if [[ -t 0 ]]; then
    read -rsp "$1 in ${file##*/}: " new
    echo >&2
    read -rsp "again: " again
    echo >&2
    [[ $new == "$again" ]] || die "the two did not match; nothing changed"
  else
    new=$(
      cat
      printf x
    )
    new=${new%x}
  fi
  [[ -n $new ]] || die "empty; nothing changed"
  # sops set takes JSON, so the value goes in as a JSON string.
  printf '%s' "$new" | jq -Rs . | sops set --value-stdin "$file" "$(index "$1")"
  fetch "$1" && [[ $got == "$new" ]] || die "$1 did not read back the same; check git diff ${file##*/}"
  printf '%s: set, %d chars\n' "$1" "${#new}"
  exit 0
fi

# A failed extract below then means a missing key, not a missing age key.
sops decrypt "$file" >/dev/null || die "could not decrypt ${file##*/}"

if [[ ! -t 0 ]]; then
  (($# == 1)) || die "compare one key at a time with stdin"
  want=$(
    cat
    printf x
  )
  want=${want%x}
  fetch "$1" || die "$1: missing"
  if [[ $got == "$want" ]]; then
    echo "$1: equal"
  elif [[ ${got%$'\n'} == "${want%$'\n'}" ]]; then
    echo "$1: equal apart from a trailing newline"
  else
    echo "$1: differs"
    exit 1
  fi
  exit 0
fi

status=0
for key; do
  if fetch "$key"; then
    printf '%s: set, %d chars, %s\n' "$key" "${#got}" "$(shape "$got")"
  else
    printf '%s: missing\n' "$key"
    status=1
  fi
done
exit "$status"
