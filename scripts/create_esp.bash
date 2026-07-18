#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/lib/util.bash"

if [ "$#" -ne 2 ]; then
  echo_error "Usage: $0 <copy src> <output>"
  exit 1
fi

cpsrc=$1
out=$2

MiB=$((1024 * 1024))
start_mib=1
size_mib=64

echo_normal "Creating disk image: $out"
dd \
  if=/dev/zero \
  of="$out" \
  bs=1M \
  count=$size_mib \
  2>/dev/null

echo_normal "Creating GPT with an EFI System Partition"
parted -s "$out" mklabel gpt
parted -s "$out" mkpart ESP fat32 ${start_mib}MiB 100%
parted -s "$out" set 1 esp on

echo_normal "Formatting ESP as FAT32"
mkfs.vfat \
  -F 32 \
  -n "URTHR" \
  --offset=$((start_mib * MiB / 512)) \
  "$out" \
  1>/dev/null

function copy()
{
  local src=$1
  local dst=$2

  mcopy \
    -i "$out"@@$((start_mib * MiB)) \
    -o \
    -s \
    $src \
    "::${dst#/}"
}

echo_normal "Setting up ESP contents"
copy "$cpsrc/*" /

echo_normal "Done"
