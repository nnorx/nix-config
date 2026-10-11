# Fails when / is not mounted from the device this host's config declares.
# See modules/root-check.nix. Built with writeShellApplication, which adds the
# shebang, errexit, nounset and pipefail.
#
# usage: root-check <expected root device>
#
# Both sides are resolved to the device node, since the config names a
# /dev/disk/by-* link and the mount table names the node. `readlink -m` rather
# than `-f`: an expected link that does not exist, as when the NVMe has dropped
# off the bus, then resolves to itself and fails to match, where `-f` prints
# nothing and fails outright if /dev/disk/by-uuid is missing too. `findmnt -v`
# leaves off the `[/subvolume]` a btrfs or bind-mounted root would otherwise
# carry, which no config's device has.

expected=$1
mounted=$(findmnt -nvo SOURCE /)

want=$(readlink -m "$expected")
have=$(readlink -m "$mounted")

if [ "$want" = "$have" ]; then
  echo "root is $expected ($have), as declared"
  exit 0
fi

echo "root is $mounted ($have), but the config declares $expected ($want)" >&2
echo "booted from a fallback root; see docs/recovery.md" >&2
exit 1
