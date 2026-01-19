# This is the container image that runs the forgejo actions. Instead of
# repeatedly installing system dependencies in CI, install them once here, and
# bake them into the image.

FROM debian:12

RUN apt-get update && apt-get install -y \
    nodejs \
    git \
    build-essential \
    pkg-config \
    libasound-dev \
    libpulse-dev \
    libglfw3-dev \
    zstd
