FROM ubuntu:18.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      software-properties-common \
      git \
      curl \
      ca-certificates \
      tzdata \
      pkg-config \
      cmake \
      ninja-build \
      autoconf \
      automake \
      libtool \
      unzip \
      zip \
 && add-apt-repository -y ppa:ubuntu-toolchain-r/test \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      gcc-11 \
      g++-11 \
 && rm -rf /var/lib/apt/lists/*

RUN update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 90 \
    --slave /usr/bin/g++ g++ /usr/bin/g++-11

ENV CC=gcc-11
ENV CXX=g++-11

WORKDIR /workspace
