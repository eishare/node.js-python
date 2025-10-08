#!/bin/sh
set -e

echo "🔍 检查系统环境与依赖..."
if command -v apk >/dev/null 2>&1; then
  apk add --no-cache curl bash openssl coreutils util-linux
else
  apt-get update -y >/dev/null 2>&1
  apt-get install -y curl bash openssl uuid-runtime >/dev/null 2>&1
fi

WORKDIR="/data/tuic"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

PORT="${1:-443}"
UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
PASSWORD=$(openssl rand -hex 16)
SNI="www.bing.com"

echo "✅ 使用端口: $PORT"
echo "🔑 UUID: $UUID"
echo "🔑 密码: $PASSWORD"

if [ ! -f "$WORKDIR/cert.pem" ]; then
  echo "🔐 生成自签证书..."
  openssl ecparam -genkey -name prime256v1 -out "$WORKDIR/private.key"
  openssl req -new -x509 -days 3650 -key "$WORKDIR/private.key" -out "$WORKDIR/cert.pem" -subj "/CN=$SNI"
fi

echo "📥 下载 TUIC 静态版 (musl)..."
curl -L -o tuic-server https://github.com/EAimTY/tuic/releases/download/0.8.5/tuic-server-x86_64-unknown-linux-musl
chmod +x tuic-server

cat > "$WORKDIR/config.json" <<EOF
{
  "server": "[::]:$PORT",
  "users": {
    "$UUID": "$PASSWORD"
  },
  "certificate": "$WORKDIR/cert.pem",
  "private_key": "$WORKDIR/private.key",
  "congestion_control": "bbr",
  "alpn": ["h3"],
  "udp_relay_mode": "native",
  "log_level": "warn"
}
EOF

IP=$(curl -s ipv4.icanhazip.com || echo "127.0.0.1")
LINK="tuic://${UUID}:${PASSWORD}@${IP}:${PORT}?congestion_control=bbr&alpn=h3&sni=$SNI&udp_relay_mode=native&allowInsecure=1#TUIC-${IP}"
echo "$LINK" > tuic_link.txt

echo "📱 TUIC 链接: $LINK"

echo "🚀 启动 TUIC 服务..."
./tuic-server -c config.json >/dev/null 2>&1 &
sleep 1

if pgrep -x tuic-server >/dev/null 2>&1; then
  echo "✅ 启动成功，服务正在运行..."
else
  echo "❌ 启动失败，请检查容器是否支持执行二进制"
fi
