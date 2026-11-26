FROM ubuntu:24.04 AS builder

RUN apt-get update && apt-get install -y \
        build-essential \
        make \
        bison \
        bc \
        flex \
        gcc-aarch64-linux-gnu \
        libssl-dev \
        device-tree-compiler \
        wget \
        cpio \
        unzip \
        rsync \
        sudo \
        fdisk \
        dosfstools \
        file \
        git \
        socat \
        qemu-system-arm \
        tar \
        curl \
        ninja-build \
        libglib2.0-dev \
        libcapstone-dev \
        libslirp-dev \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

# QEMU
ENV QEMU_VERSION=11.1.3
ENV QEMU_DIR=/opt/qemu
WORKDIR /opt
RUN curl https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz | tar xvJf -
WORKDIR /opt/qemu-${QEMU_VERSION}
RUN ./configure \
    --target-list=aarch64-softmmu,x86_64-softmmu \
    --enable-slirp \
    --disable-tools \
    --disable-docs \
    --prefix=$QEMU_DIR
RUN make -j$(nproc)
RUN make install
WORKDIR /opt
RUN rm $QEMU_DIR/share/qemu/edk2-*
RUN rm -rf /opt/qemu-${QEMU_VERSION}
RUN strip $QEMU_DIR/bin/qemu-system-*

#####################################################

FROM ubuntu:24.04 AS runtime

ENV QEMU_DIR=/opt/qemu

# Install shared libraries required by QEMU.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libcapstone4 \
        libfdt1 \
        libglib2.0-0t64 \
        libpixman-1-0 \
        libslirp0 \
        zlib1g \
        ovmf \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder $QEMU_DIR $QEMU_DIR

WORKDIR /work
