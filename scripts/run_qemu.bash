#!/bin/bash
#
# Run QEMU with the given argv as-is, then translate its exit code.
#
# Usage: run_qemu.bash <arch> <qemu-binary> [qemu-args...]

set -uo pipefail

source "$(dirname "$0")/lib/util.bash"

if [ "$#" -lt 2 ]; then
  echo_error "Usage: $0 <arch> <qemu-binary> [qemu-args...]"
  exit 1
fi

arch=$1
shift

"$@"
status=$?

if [ "$arch" = "x86_64" ]; then
  exit $((status >> 1))
else
  exit "$status"
fi
