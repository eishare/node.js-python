#!/bin/sh
set -e

echo "🔍 检查系统环境与依赖..."

# 安装基础依赖
if command -v apk >/dev/null 2>&1; then
  apk add --no-cache curl bash openssl coreutils util-linux >/dev/null 2>&1
  OS="alpine"
else
  apt-get update -y >/dev/null 2>&1
  apt-get install -y curl bash openssl uuid-runtime >/dev/null 2>&1
  OS="debian"
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
echo "🎯 SNI: $SNI"

# 生成证书
if [ ! -f "$WORKDIR/cert.pem" ]; then
  echo "🔐 生成自签证书..."
  openssl ecparam -genkey -name prime256v1 -out "$WORKDIR/private.key"
  openssl req -new -x509 -days 3650 -key "$WORKDIR/private.key" -out "$WORKDIR/cert.pem" -subj "/CN=$SNI"
else
  echo "🔐 已存在证书，跳过生成"
fi

# 检测系统架构
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)
    TUIC_FILE="tuic-server-x86_64-unknown-linux-musl"
    ;;
  aarch64|arm64)
    TUIC_FILE="tuic-server-aarch64-unknown-linux-musl"
    ;;
  *)
    echo "❌ 不支持的架构: $ARCH"
    exit 1
    ;;
esac

TUIC_URL="https://github.com/EAimTY/tuic/releases/download/0.8.5/${TUIC_FILE}"

echo "📥 下载 TUIC (${TUIC_FILE})..."
curl -L -o tuic-server "$TUIC_URL"
chmod +x tuic-server

if ! ./tuic-server -v >/dev/null 2>&1; then
  echo "❌ TUIC 无法执行，请检查架构或系统环境"
  exit 1
fi

# 生成配置文件
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

# 获取公网 IP
IP=$(curl -s ipv4.icanhazip.com || echo "127.0.0.1")

LINK="tuic://${UUID}:${PASSWORD}@${IP}:${PORT}?congestion_control=bbr&alpn=h3&sni=$SNI&udp_relay_mode=native&allowInsecure=1#TUIC-${IP}"
echo "$LINK" > "$WORKDIR/tuic_link.txt"

echo "📱 TUIC 链接: $LINK"
echo "🚀 启动 TUIC 服务..."

# 启动 TUIC 服务
nohup ./tuic-server -c config.json >/dev/null 2>&1 &
sleep 2

if pgrep -x tuic-server >/dev/null 2>&1; then
  echo "✅ 启动成功，TUIC 正在运行中..."
else
  echo "❌ 启动失败，请检查系统是否支持执行二进制文件"
fi
