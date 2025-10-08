#!/bin/sh
set -e

echo "🔍 检查系统环境与依赖..."

# 统一安装依赖
if command -v apk >/dev/null 2>&1; then
  PKG="apk add --no-cache curl bash openssl coreutils util-linux"
elif command -v apt-get >/dev/null 2>&1; then
  apt-get update -y >/dev/null 2>&1
  apt-get install -y curl bash openssl uuid-runtime >/dev/null 2>&1
else
  echo "❌ 无法检测到支持的包管理器 (apk 或 apt-get)"
  exit 1
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

# 生成自签证书
if [ ! -f "$WORKDIR/cert.pem" ]; then
  echo "🔐 生成自签 ECDSA 证书..."
  openssl ecparam -genkey -name prime256v1 -out "$WORKDIR/private.key"
  openssl req -new -x509 -days 3650 -key "$WORKDIR/private.key" -out "$WORKDIR/cert.pem" -subj "/CN=$SNI"
else
  echo "🔐 已存在证书，跳过生成"
fi

# 检测架构
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)   ARCH_URL="x86_64-unknown-linux-gnu" ;;
  aarch64)  ARCH_URL="aarch64-unknown-linux-gnu" ;;
  armv7l)   ARCH_URL="armv7-unknown-linux-gnueabihf" ;;
  *)        ARCH_URL="x86_64-unknown-linux-gnu" ;;
esac

BIN="./tuic-server"
DOWNLOAD_URL="https://github.com/EAimTY/tuic/releases/download/0.8.5/tuic-server-${ARCH_URL}"

echo "📥 正在下载 TUIC (${ARCH_URL})..."
curl -L -o "$BIN" "$DOWNLOAD_URL" --retry 3 --connect-timeout 10 || true

if [ ! -s "$BIN" ]; then
  echo "⚠️ 下载失败或文件无效，尝试使用 musl 版本..."
  curl -L -o "$BIN" "https://github.com/EAimTY/tuic/releases/download/0.8.5/tuic-server-x86_64-unknown-linux-musl" --retry 3
fi

chmod +x "$BIN"

# 检查可执行性
if ! "$BIN" -v >/dev/null 2>&1; then
  echo "❌ TUIC 无法执行，请检查架构兼容性"
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
  "zero_rtt_handshake": true,
  "auth_timeout": "5s",
  "max_idle_time": "10s",
  "udp_relay_mode": "native",
  "log_level": "warn"
}
EOF

# 生成 TUIC 链接
IP=$(curl -s ipv4.icanhazip.com || echo "127.0.0.1")
TUIC_LINK="tuic://${UUID}:${PASSWORD}@${IP}:${PORT}?congestion_control=bbr&alpn=h3&sni=${SNI}&udp_relay_mode=native&allowInsecure=1#TUIC-${IP}"
echo "$TUIC_LINK" > "$WORKDIR/tuic_link.txt"

echo "📱 TUIC 链接已生成："
echo "$TUIC_LINK"

echo "🚀 启动 TUIC 服务中..."
if "$BIN" -c "$WORKDIR/config.json" >/dev/null 2>&1 & then
  sleep 1
  if pgrep -x "tuic-server" >/dev/null 2>&1; then
    echo "✅ 服务已启动，tuic-server 正在运行..."
  else
    echo "⚠️ 启动失败，尝试使用 musl 静态版..."
    curl -L -o "$BIN" "https://github.com/EAimTY/tuic/releases/download/0.8.5/tuic-server-x86_64-unknown-linux-musl" --retry 3
    chmod +x "$BIN"
    "$BIN" -c "$WORKDIR/config.json" >/dev/null 2>&1 &
    sleep 1
    if pgrep -x "tuic-server" >/dev/null 2>&1; then
      echo "✅ 使用 musl 版成功启动 TUIC 服务"
    else
      echo "❌ 启动失败，请检查容器是否支持 tuic-server"
    fi
  fi
else
  echo "❌ 启动失败，请检查日志或架构兼容性"
fi
