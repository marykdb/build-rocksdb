FROM ubuntu:18.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      git \
      curl \
      ca-certificates \
      tzdata \
      gcc-8 \
      g++-8 \
      pkg-config \
      cmake \
      ninja-build \
      autoconf \
      automake \
      libtool \
      unzip \
      zip \
 && rm -rf /var/lib/apt/lists/*

RUN update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-8 80 \
    --slave /usr/bin/g++ g++ /usr/bin/g++-8

ENV CC=gcc-8
ENV CXX=g++-8

WORKDIR /workspace
