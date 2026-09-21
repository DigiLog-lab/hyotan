#!/bin/sh
# Build rootfs-v<N>.tar.gz for the bundled guest Linux (design §6.1).
# Requires python3 >= 3.11 and network access on first run (inputs are cached in .cache/).
set -eu
cd "$(dirname "$0")"
exec python3 build.py "$@"
