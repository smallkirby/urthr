#!/bin/bash
#
# Fetch and build fio for Urthr.
#
# Usage: bench/fio/setup.bash <arch> [buildroot output dir]
#   arch: aarch64 | x86_64
#   buildroot output dir: Buildroot build directory

set -euo pipefail

source "$(dirname "$0")/../../scripts/lib/util.bash"

VERSION=3.38
URL=https://brick.kernel.dk/snaps/fio-${VERSION}.tar.gz

script_dir="$(cd "$(dirname "$0")" && pwd)"

if [ "$#" -lt 1 ]; then
  echo_error "Usage: $0 <arch> [buildroot output dir]"
  echo_error "  arch: aarch64 | x86_64"
  exit 1
fi

arch=$1
output_dir="${2:-$HOME/buildroot-2025.05/output-${arch}}"
cc="$output_dir/host/bin/${arch}-buildroot-linux-musl-gcc"

if [ ! -x "$cc" ]; then
  echo_error "Cross compiler not found: $cc"
  echo_error "Build Buildroot first: scripts/build_buildroot.bash $arch"
  exit 1
fi

# Create a directory for build.
build_dir="$script_dir/build/${arch}"
mkdir -p "$build_dir"

# Download fio source code.
tarball="$build_dir/fio-${VERSION}.tar.gz"
if [ ! -f "$tarball" ]; then
  echo_normal "Downloading $URL"
  wget -q --show-progress -O "$tarball" "$URL"
else
  echo_normal "Reusing $tarball"
fi

src="$build_dir/fio-${VERSION}"
if [ ! -d "$src" ]; then
  tar -xzf "$tarball" -C "$build_dir"
fi

# Build using the cross compiler
echo_normal "Building for $arch"
(
  cd "$src"
  ./configure \
    --cc="$cc" \
    --build-static \
    --disable-native \
    --disable-libnfs \
    --disable-shm \
    > "$build_dir/configure.log"
  make -j"$(nproc)"
)

# Copy the artifact to the target filesystem directory
dest="$output_dir/target/usr/bin"
mkdir -p "$dest"
install -m 755 "$src/fio" "$dest/fio"

# Install job files.
mkdir -p "$output_dir/target/usr/share/fio"
install -m 644 "$script_dir"/*.fio "$output_dir/target/usr/share/fio/"

echo_normal "Installed: $dest/fio"
