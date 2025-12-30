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
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

# QEMU
ENV QEMU_VERSION=10.0.0
ENV QEMU_DIR=/opt/qemu-aarch64
WORKDIR /opt
RUN curl https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz | tar xvJf -
WORKDIR /opt/qemu-${QEMU_VERSION}
RUN ./configure --target-list=aarch64-softmmu --prefix=$QEMU_DIR
RUN make -j$(nproc)
RUN make install
WORKDIR /opt
RUN rm -rf /opt/qemu-${QEMU_VERSION}

#####################################################

FROM ubuntu:24.04 AS runtime

ENV QEMU_DIR=/opt/qemu-aarch64

COPY --from=builder $QEMU_DIR $QEMU_DIR

WORKDIR /work
