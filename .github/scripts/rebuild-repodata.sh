#!/bin/bash
# Rebuilds the yum index (<arch>/repodata/) of every architecture with
# createrepo_c, from the packages committed at HEAD. Run it from the root of a
# clone. A blobless clone (--filter=blob:none) without the rpms checked out is
# enough, and is what CI uses.
#
# Only packages that are new, or were replaced since the current index was
# built, are downloaded and read. Every other package becomes an empty sparse
# file of the same size and mtime, which `createrepo_c --update` takes as
# unchanged and never opens. A package's mtime is the time of the last commit
# that touched it, so this works on a fresh clone and still catches a release
# rebuilt under the same file name.
set -euo pipefail

ARCHES=(x86_64 aarch64)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Last commit time of every package. git log lists the newest commit first, so
# the first time seen for a path wins.
declare -A commit_time
t=
while IFS= read -r line; do
  case "$line" in
    '') ;;
    @*) t=${line#@} ;;
    *) [ -n "${commit_time[$line]:-}" ] || commit_time[$line]=$t ;;
  esac
done < <(git log --format=@%ct --name-only -- '*/Packages/*.rpm')

for arch in "${ARCHES[@]}"; do
  out="$work/$arch"
  mkdir -p "$out/Packages"

  # "size mtime" of every package in the current index, by file name. A
  # package whose last commit time is its indexed mtime is unchanged. A
  # missing or unreadable index means every package is read.
  unset indexed
  declare -A indexed=()
  if python3 - "$arch" > "$work/$arch.idx" <<'EOF'
import gzip, os, sys
import xml.etree.ElementTree as ET

repo = sys.argv[1]
ns = {"r": "http://linux.duke.edu/metadata/repo",
      "c": "http://linux.duke.edu/metadata/common"}
try:
    repomd = ET.parse(os.path.join(repo, "repodata", "repomd.xml")).getroot()
    href = repomd.find("r:data[@type='primary']/r:location", ns).get("href")
    with gzip.open(os.path.join(repo, href)) as f:
        for pkg in ET.parse(f).getroot().iterfind("c:package", ns):
            print(os.path.basename(pkg.find("c:location", ns).get("href")),
                  pkg.find("c:size", ns).get("package"),
                  pkg.find("c:time", ns).get("file"))
except (OSError, ET.ParseError, AttributeError) as e:
    print(f"{repo}: no usable index ({e})", file=sys.stderr)
    sys.exit(1)
EOF
  then
    cp -r "$arch/repodata" "$out/"
    while read -r name size mtime; do
      indexed[$name]="$size $mtime"
    done < "$work/$arch.idx"
  else
    echo "$arch: reading every package"
  fi

  read_count=0
  reused_count=0
  # --name-only: asking for sizes (-l) would download every blob.
  while IFS= read -r path; do
    name=${path##*/}
    mtime=${commit_time[$path]}
    dest="$out/Packages/$name"
    indexed_entry=${indexed[$name]:-}
    if [ -n "$indexed_entry" ] && [ "${indexed_entry#* }" = "$mtime" ]; then
      truncate -s "${indexed_entry%% *}" "$dest"
      reused_count=$((reused_count + 1))
    else
      git cat-file blob "HEAD:$path" > "$dest"
      read_count=$((read_count + 1))
    fi
    touch -d "@$mtime" "$dest"
  done < <(git ls-tree -r --name-only HEAD -- "$arch/Packages/" | grep '\.rpm$')

  # Never publish an empty index because the package listing failed.
  if [ $((read_count + reused_count)) -eq 0 ]; then
    echo "$arch: no packages found at HEAD; not touching the index" >&2
    exit 1
  fi

  # gz and no sqlite databases: what every yum and dnf version can read.
  createrepo_c --update --general-compress-type=gz --no-database "$out"

  rm -rf "$arch/repodata"
  cp -r "$out/repodata" "$arch/"
  echo "$arch: read ${read_count} packages, reused ${reused_count} from the old index"
done
