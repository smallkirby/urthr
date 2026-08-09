#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/lib/util.bash"

if [ "$#" -ne 2 ]; then
  echo_error "Usage: $0 <external rootfs dir> <bootfs staging dir>"
  exit 1
fi

src=$1
dst=$2

if [ ! -d "$src" ]; then
  echo_error "External rootfs directory not found: $src"
  exit 1
fi

echo_normal "Merging external rootfs from $src into $dst"
python3 "$(dirname "$0")/lib/materialize_symlinks.py" "$src" "$dst"

echo_normal "Done"
