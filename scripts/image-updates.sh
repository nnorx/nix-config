#!/usr/bin/env bash
# Reports how far each pinned container image is behind its registry, as a
# Markdown table on stdout. Run by .github/workflows/image-updates.yml, which
# files the table as an issue; it never changes a pin, because moving either
# image runs one-way database migrations (docs/unifi.md, "Upgrading").
#
# Reads `registry/repo:tag@sha256:...` references on stdin, one per line.
# Needs skopeo, and network access to each registry. Reads manifests only
# (`inspect --raw`), never image blobs.
#
# Two ways a pin falls behind, reported separately:
#
#   The same tag, rebuilt. linuxserver republishes a version tag when it
#   rebuilds on a patched base image, and mongo's `8.0` moves with every 8.0.x
#   release. The pin keeps the old build and its unpatched packages.
#
#   A newer version. Compared only with tags shaped like the pinned one, so
#   `10.6.101` is weighed against other x.y.z tags and `8.0` against other x.y
#   tags, never against `latest` or `8.0.15`. The newest within the same major
#   version is listed apart, since a major upgrade is its own decision.
#
# Only a fixed release, a tag of three or more parts like `10.6.101`, counts
# as behind when a newer version exists: its tag is rarely rebuilt once
# superseded, so the version is the only signal. A shorter tag like mongo's
# `8.0` names a release line, which moves by itself and shows up as a rebuild;
# a newer line is a database change made on purpose, so it is shown and not
# counted, or the issue would never close.
#
# Exit status: 0 when nothing counts as behind, 2 when something does, 1 when
# a registry could not be read.
set -euo pipefail

behind=0
failed=0
manifest=$(mktemp)

echo "| Image | Pinned | Same tag now | Newest in major | Newest |"
echo "|---|---|---|---|---|"

while read -r image; do
  [[ -n $image ]] || continue
  ref=${image%@*}
  pinned=${image#*@}
  repo=${ref%:*}
  tag=${ref##*:}

  if ! skopeo inspect --raw "docker://$ref" >"$manifest" 2>/dev/null; then
    echo "| \`$repo\` | \`$tag\` | could not read | | |"
    failed=1
    continue
  fi
  current=$(skopeo manifest-digest "$manifest")
  if [[ $current == "$pinned" ]]; then
    same="matches"
  else
    same="rebuilt, \`${current:0:19}\`"
    behind=1
  fi

  newest_major="" newest=""
  if [[ $tag =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    # The pinned tag's shape as a pattern: every run of digits becomes [0-9]+.
    shape="^$(sed -E 's/[0-9]+/[0-9]+/g; s/\./\\./g' <<<"$tag")\$"
    tags=$(skopeo list-tags "docker://$repo" | jq -r '.Tags[]' | grep -E "$shape" | sort -V || true)
    newest=$(tail -n 1 <<<"$tags")
    newest_major=$(grep -E "^${tag%%.*}\." <<<"$tags" | tail -n 1 || true)
    if [[ $tag =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
      for candidate in "$newest_major" "$newest"; do
        if [[ -n $candidate && $candidate != "$tag" &&
          $(printf '%s\n%s\n' "$tag" "$candidate" | sort -V | tail -n 1) == "$candidate" ]]; then
          behind=1
        fi
      done
    fi
  fi

  echo "| \`$repo\` | \`$tag\` | $same | ${newest_major:+\`$newest_major\`} | ${newest:+\`$newest\`} |"
done

rm -f "$manifest"
if ((failed)); then exit 1; fi
if ((behind)); then exit 2; fi
exit 0
