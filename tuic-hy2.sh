#!/bin/bash
# =============================================================
# 🌀 TUIC v1.5.9 自动部署（支持 musl / glibc，Claw Cloud 持久化版）
# 修复下载 404 问题，自动选择正确文件名
# =============================================================
set -euo pipefail
IFS=$'\n\t'

PORT=${1:-443}
INSTALL_DIR="/root/tuic"
VERSION="1.5.9"
MASQ_DOMAIN="www.bing.com"

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "🔍 检查系统依赖..."
if command -v apk >/dev/null 2>&1; then
  apk add --no-cache curl openssl coreutils grep sed >/dev/null
elif command -v apt >/dev/null 2>&1; then
  apt update -qq >/dev/null
  apt install -y curl openssl uuid-runtime >/dev/null
else
  echo "⚠️ 未检测到支持的包管理器"
fi
echo "✅ 依赖检查完成"
echo "✅ 使用端口: $PORT"

UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
PASS=$(openssl rand -hex 16)
echo "🔑 UUID: $UUID"
echo "🔑 密码: $PASS"
echo "🎯 SNI: ${MASQ_DOMAIN}"

# 生成证书
if [[ ! -f tuic-cert.pem || ! -f tuic-key.pem ]]; then
  echo "🔐 生成自签证书..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 3650 -nodes -keyout tuic-key.pem -out tuic-cert.pem \
    -subj "/CN=${MASQ_DOMAIN}" >/dev/null 2>&1
  echo "✅ 证书生成完成"
else
  echo "✅ 检测到已有证书，跳过生成"
fi

# 检测架构和 libc
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) ARCH="x86_64" ;;
  aarch64|arm64) ARCH="aarch64" ;;
  *) echo "❌ 不支持的架构: $ARCH"; exit 1 ;;
esac

if ldd /bin/sh 2>&1 | grep -q musl; then
  LIB="unknown-linux-musl"
  echo "⚙️ 检测到系统使用 musl (Alpine)"
else
  LIB="unknown-linux-gnu"
  echo "⚙️ 检测到系统使用 glibc (Debian/Ubuntu)"
fi

# 修正下载地址
TUIC_URL="https://github.com/Itsusinn/tuic/releases/download/v${VERSION}/tuic-server-${ARCH}-${LIB}"
echo "⬇️ 下载 TUIC: $TUIC_URL"

if ! curl -Lf -o tuic-server "$TUIC_URL"; then
  echo "❌ 下载失败，请手动检查该版本的可用文件名"
  exit 1
fi
chmod +x tuic-server
echo "✅ TUIC 下载完成并已赋予执行权限"

# 生成配置
cat > server.toml <<EOF
log_level = "off"
server = "0.0.0.0:${PORT}"
zero_rtt_handshake = true
udp_relay_ipv6 = false
auth_timeout = "10s"
task_negotiation_timeout = "5s"
gc_interval = "10s"
gc_lifetime = "10s"
max_external_packet_size = 8192

[users]
${UUID} = "${PASS}"

[tls]
self_sign = false
certificate = "tuic-cert.pem"
private_key = "tuic-key.pem"
alpn = ["h3"]

[quic]
send_window = 33554432
receive_window = 16777216
congestion_control = { controller = "bbr", initial_window = 4194304 }
EOF
echo "✅ 配置文件生成完成"

# 获取公网 IP
SERVER_IP=$(curl -s --connect-timeout 5 https://api.ipify.org || echo "YOUR_SERVER_IP")

# 输出连接信息
echo "tuic://${UUID}:${PASS}@${SERVER_IP}:${PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1#TUIC-${SERVER_IP}" | tee tuic_link.txt

# 启动脚本
cat > start.sh <<EOF
#!/bin/bash
cd "$INSTALL_DIR"
nohup ./tuic-server -c server.toml >/dev/null 2>&1 &
echo "✅ TUIC 已启动"
EOF
chmod +x start.sh

echo "🚀 启动 TUIC 服务中..."
bash start.sh

echo "🎉 部署完成！"
echo "📄 配置: ${INSTALL_DIR}/server.toml"
echo "🔗 链接: ${INSTALL_DIR}/tuic_link.txt"
echo "⚙️ 启动脚本: ${INSTALL_DIR}/start.sh"
