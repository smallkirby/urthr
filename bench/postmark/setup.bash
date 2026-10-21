#!/bin/bash
#
# Fetch and build PostMark benchmark for Urthr.
#
# Usage: bench/postmark/setup.bash <arch> [buildroot output dir]
#   arch: aarch64 | x86_64
#   buildroot output dir: Buildroot build directory

set -euo pipefail

source "$(dirname "$0")/../../scripts/lib/util.bash"

URL=https://mirror.ircam.fr/pub/pkgsrc/distfiles/postmark-1_5.c

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

# Download PostMark source code.
src="$build_dir/postmark-1_5.c"
if [ ! -f "$src" ]; then
  echo_normal "Downloading $URL"
  wget -q --show-progress -O "$src" "$URL"
else
  echo_normal "Reusing $src"
fi

# musl does not provide getwd()
shim="$build_dir/getwd.c"
cat > "$shim" <<'EOF'
#include <unistd.h>
char *getwd(char *buf) { return getcwd(buf, 256); }
EOF

# Build using the cross compiler
echo_normal "Building for $arch"
"$cc" -O3 -static -o "$build_dir/postmark" "$src" "$shim"

# Copy the artifact to the target filesystem directory
dest="$output_dir/target/usr/bin"
mkdir -p "$dest"
install -m 755 "$build_dir/postmark" "$dest/postmark"

echo_normal "Installed: $dest/postmark"
