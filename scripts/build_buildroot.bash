#!/bin/bash
#
# Fetch and build the Buildroot userland.
#
# Usage: scripts/build_buildroot.bash <arch> [output dir]
#   arch: aarch64 | x86_64
#   output dir: Buildroot out-of-tree build directory
#
# Safe to re-run. Skips the download and extract if the source tree already exists,
# and always re-applies the defconfig before building.

set -euo pipefail

source "$(dirname "$0")/lib/util.bash"

version="2025.05"
url="https://buildroot.org/downloads/buildroot-${version}.tar.gz"
sha256="47994509ee592f0ac7f964a016096e6a8a0b6c1e9f008fd0d25ba677f6109b91"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

if [ "$#" -lt 1 ]; then
  echo_error "Usage: $0 <arch> [output dir]"
  echo_error "  arch: aarch64 | x86_64"
  exit 1
fi

arch=$1
defconfig="$repo_root/scripts/buildroot/defconfig.${arch}"
if [ ! -f "$defconfig" ]; then
  echo_error "No defconfig for arch '$arch': $defconfig not found"
  exit 1
fi

export URTHR_BUSYBOX_CONFIG="$repo_root/scripts/buildroot/busybox.config"
if [ ! -f "$URTHR_BUSYBOX_CONFIG" ]; then
  echo_error "BusyBox config not found: $URTHR_BUSYBOX_CONFIG"
  exit 1
fi

buildroot_src="$HOME/buildroot-${version}"
output_dir="${2:-$buildroot_src/output-${arch}}"

if [ ! -d "$buildroot_src" ]; then
  echo_normal "Downloading Buildroot ${version}"
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT

  tarball="$tmpdir/buildroot-${version}.tar.gz"
  wget -q --show-progress -O "$tarball" "$url"

  echo_normal "Verifying checksum"
  echo "$sha256  $tarball" | sha256sum -c - >/dev/null

  echo_normal "Extracting to $buildroot_src"
  tar -xzf "$tarball" -C "$tmpdir"
  mv "$tmpdir/buildroot-${version}" "$buildroot_src"
else
  echo_normal "Reusing existing Buildroot source at $buildroot_src"
fi

cd "$buildroot_src"
echo_normal "Applying $defconfig (output: $output_dir)"
make O="$output_dir" DEFCONFIG="$defconfig" defconfig

echo_normal "Building"
make O="$output_dir" -j"$(nproc)" busybox-dirclean
make O="$output_dir" -j"$(nproc)"

echo_normal "Done: $output_dir/target"
