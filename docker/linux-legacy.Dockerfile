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
      gcc-10 \
      g++-10 \
 && rm -rf /var/lib/apt/lists/*

RUN update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-10 90 \
    --slave /usr/bin/g++ g++ /usr/bin/g++-10

ENV CC=gcc-10
ENV CXX=g++-10

WORKDIR /workspace
