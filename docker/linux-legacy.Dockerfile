FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
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
 && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
