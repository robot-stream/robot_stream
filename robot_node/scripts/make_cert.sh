#!/usr/bin/env bash
# Chứng chỉ tự ký cho TLS (tls:=true): wss://robot:9091 và https://robot:8889 (WHEP).
# Chạy TRÊN robot:  make_cert.sh [ip-robot]   (mặc định: mọi IPv4 của máy)
# In vân tay SHA-256 để ghim trong app (--dart-define=ROBOT_CERT_SHA256=…).
set -eu
DIR=~/.config/robot_stream/tls
mkdir -p "$DIR"; chmod 700 ~/.config/robot_stream "$DIR"
IPS=${1:-$(hostname -I)}
SAN="DNS:localhost,DNS:$(hostname)"
for ip in $IPS; do case $ip in *:*) ;; *) SAN="$SAN,IP:$ip" ;; esac; done
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
  -subj "/CN=robot_stream $(hostname)" -addext "subjectAltName=$SAN" \
  -keyout "$DIR/key.pem" -out "$DIR/cert.pem" 2>/dev/null
chmod 600 "$DIR/key.pem"
echo "Đã tạo $DIR/cert.pem ($SAN)"
echo -n "Vân tay SHA-256: "
openssl x509 -in "$DIR/cert.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d : | tr A-F a-f
