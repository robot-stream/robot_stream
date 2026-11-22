#!/usr/bin/env bash
# Tải MediaMTX (arm64) vào ~/robot_stream/mediamtx và kiểm checksum. Không cần sudo.
# Dùng (trên robot): install_mediamtx.sh [phiên bản]   (mặc định v1.21.3 – bản đã đo 04/11/2026)
set -eu
V=${1:-v1.21.3}
ARCH=linux_arm64
DEST=~/robot_stream/mediamtx
BASE="https://github.com/bluenviron/mediamtx/releases/download/$V"

mkdir -p "$DEST" && cd "$DEST"
curl -sSLf -o m.tgz "$BASE/mediamtx_${V}_${ARCH}.tar.gz"
curl -sSLf -o checksums.sha256 "$BASE/checksums.sha256"
grep "mediamtx_${V}_${ARCH}.tar.gz" checksums.sha256 | awk '{print $1"  m.tgz"}' | sha256sum -c -
tar xzf m.tgz && rm m.tgz
./mediamtx --help | head -3 | tail -1
