# This is the Docker file of the Honey Potion artifact.
# To run the different research questions, do:
#
# docker run --rm docker-artifact bash rq1.sh
# docker run --rm docker-artifact bash rq2.sh
# docker run --rm docker-artifact bash rq4.sh
# docker run --rm docker-artifact bash rq5.sh
#
# Author: Fernando Magno Quintao Pereira
# Date: August 16th, 2024

# Use an official Ubuntu as a base image
FROM ubuntu:20.04

# Set non-interactive mode for apt
ENV DEBIAN_FRONTEND=noninteractive

# Install basic dependencies
RUN apt-get update && apt-get install -y \
    wget \
    git \
    build-essential \
    libelf-dev \
    zlib1g-dev \
    gcc-multilib \
    python3 \
    python3-pip \
    python3-matplotlib \
    sudo \
    lsb-release \
    software-properties-common \
    gnupg \
    locales \
    tmux && \
    locale-gen en_US.UTF-8 && \
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 && \
    rm -rf /var/lib/apt/lists/*

# Set environment variables for the locale
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

# Add LLVM apt repository and install Clang 16
RUN wget https://apt.llvm.org/llvm.sh && \
    chmod +x llvm.sh && \
    ./llvm.sh 16 && \
    rm llvm.sh

# Install Clang and LLVM tools
RUN apt-get update && \
    apt-get install -y clang-16 llvm-16 llvm-16-tools

# Set up update-alternatives for Clang and LLVM tools
RUN update-alternatives --install /usr/bin/clang clang /usr/bin/clang-16 100 && \
    update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-16 100 && \
    update-alternatives --install /usr/bin/llc llc /usr/bin/llc-16 100 && \
    update-alternatives --install /usr/bin/opt opt /usr/bin/opt-16 100 && \
    update-alternatives --install /usr/bin/llvm-strip llvm-strip /usr/bin/llvm-strip-16 100 && \
    update-alternatives --install /usr/bin/llvm-ar llvm-ar /usr/bin/llvm-ar-16 100 && \
    update-alternatives --install /usr/bin/llvm-as llvm-as /usr/bin/llvm-as-16 100

# Install Elixir
RUN wget https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb && \
    dpkg -i erlang-solutions_2.0_all.deb && \
    apt-get update && \
    apt-get install -y elixir && \
    rm erlang-solutions_2.0_all.deb

# Install Hex, the package manager for Elixir
RUN mix local.hex --force

# Install libbpf
RUN cd /tmp && \
    git clone https://github.com/libbpf/libbpf && \
    cd libbpf/src/ && \
    mkdir build bpf && \
    BUILT_STATIC_ONLY=y OBJDIR=build DESTDIR=bpf make install && \
    cp -r ./build/libbpf.a /usr/local/lib && \
    cp -r ./bpf/usr/include/bpf /usr/local/include && \
    rm -rf /tmp/libbpf

# Install BPF tools
RUN apt-get update && apt-get install -y linux-tools-$(uname -r) || \
    (cd /tmp && \
    git clone --recurse-submodules https://github.com/libbpf/bpftool.git && \
    cd bpftool/src && \
    make install LLVM_STRIP=llvm-strip-16 && \
    rm -rf /tmp/bpftool)

# Clone the Honey Potion repository
RUN git clone https://github.com/lac-dcc/honey-potion.git /honey-potion

# Set the working directory
WORKDIR /honey-potion/artifact

# Run the scripts to reproduce the experiments
CMD ["bash", "-c", "bash rq1.sh && bash rq2.sh && bash rq4.sh && bash rq5.sh"]
