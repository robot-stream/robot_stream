#!/usr/bin/env bash
# Download MediaMTX (linux_amd64 or linux_arm64) into ~/robot_stream/mediamtx
# and verify its SHA-256 checksum. No sudo required.
#
# Usage (on the robot):
#   install_mediamtx.sh [version]   # default: v1.21.3
set -euo pipefail

V=${1:-v1.21.3}
case "$(uname -m)" in
  x86_64|amd64)  ARCH=linux_amd64 ;;
  aarch64|arm64) ARCH=linux_arm64 ;;
  *)
    echo "Unsupported CPU architecture: $(uname -m) (expected x86_64 or aarch64/arm64)" >&2
    exit 1
    ;;
esac

DEST=~/robot_stream/mediamtx
BASE="https://github.com/bluenviron/mediamtx/releases/download/$V"

echo "Installing MediaMTX $V ($ARCH) into $DEST..."
mkdir -p "$DEST"
cd "$DEST"
curl -sSLf -o m.tgz "$BASE/mediamtx_${V}_${ARCH}.tar.gz"
curl -sSLf -o checksums.sha256 "$BASE/checksums.sha256"
grep "mediamtx_${V}_${ARCH}.tar.gz" checksums.sha256 | awk '{print $1"  m.tgz"}' | sha256sum -c -
tar xzf m.tgz
rm -f m.tgz
./mediamtx --help | head -3 | tail -1
