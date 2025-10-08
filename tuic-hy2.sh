#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

TUIC_VERSION="1.5.9"
MASQ_DOMAIN="www.bing.com"
SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
TUIC_BIN="./tuic-server"

echo "🔍 检查系统依赖..."
if command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl openssl util-linux
elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null
    apt-get install -y curl openssl uuid-runtime >/dev/null
fi
echo "✅ 依赖检查完成"

# 获取端口
TUIC_PORT="${1:-443}"
echo "✅ 指定端口: $TUIC_PORT"

# 生成 UUID 与密码
TUIC_UUID=$(uuidgen)
TUIC_PASSWORD=$(openssl rand -hex 16)
echo "🔑 UUID: $TUIC_UUID"
echo "🔑 密码: $TUIC_PASSWORD"
echo "🎯 SNI: $MASQ_DOMAIN"

# 生成证书
if [[ ! -f "$CERT_PEM" || ! -f "$KEY_PEM" ]]; then
    echo "🔐 生成自签证书..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
fi

# 检测架构
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) ARCH="x86_64" ;;
    aarch64|arm64) ARCH="aarch64" ;;
    *) echo "❌ 不支持的架构: $ARCH"; exit 1 ;;
esac

# 检测 libc
if ldd --version 2>&1 | grep -q musl; then
    LIBC="musl"
    echo "⚙️ 检测到系统使用 musl"
else
    LIBC="gnu"
    echo "⚙️ 检测到系统使用 glibc"
fi

# 构造下载链接
TUIC_URL="https://github.com/Itsusinn/tuic/releases/download/v${TUIC_VERSION}/tuic-server-${ARCH}-unknown-linux-${LIBC}"
echo "⬇️ 下载 TUIC: $TUIC_URL"

if ! curl -L -f -o "$TUIC_BIN" "$TUIC_URL"; then
    echo "❌ 下载失败，请检查网络或手动下载 $TUIC_URL"
    exit 1
fi
chmod +x "$TUIC_BIN"

# 生成配置文件
cat > "$SERVER_TOML" <<EOF
log_level = "info"
server = "0.0.0.0:${TUIC_PORT}"
zero_rtt_handshake = true
dual_stack = false
auth_timeout = "10s"

[users]
${TUIC_UUID} = "${TUIC_PASSWORD}"

[tls]
certificate = "${CERT_PEM}"
private_key = "${KEY_PEM}"
alpn = ["h3"]

[quic]
congestion_control = { controller = "bbr", initial_window = 4194304 }
EOF

# 启动
echo "🚀 启动 TUIC 服务..."
./tuic-server -c "$SERVER_TOML" &
sleep 2
if pgrep -x tuic-server >/dev/null; then
    echo "✅ TUIC 已成功运行在端口 ${TUIC_PORT}"
else
    echo "❌ 启动失败，请检查日志"
fi

# 生成链接
IP=$(curl -s https://api.ipify.org || echo "YOUR_IP")
echo "tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${IP}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&sni=${MASQ_DOMAIN}&allowInsecure=1#tuic-${IP}"
