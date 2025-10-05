#!/usr/bin/env bash
# TUIC 一键部署脚本（支持 x86_64 / aarch64，Alpine/Debian/Ubuntu/CentOS）
# 默认证书域名: www.bing.com
# Usage: bash tuic.sh [PORT]

set -euo pipefail
IFS=$'\n\t'

# ---------------- 配置 ----------------
MASQ_DOMAIN="www.bing.com"
TUIC_BIN="/usr/local/bin/tuic-server"
SERVER_TOML="/etc/tuic-server.toml"
SERVICE_NAME="tuic-server"
DEFAULT_BASE_PORT=10240
PORT_RANGE=50000
# ---------------------------------------

# 获取端口参数或随机生成
PORT="${1:-}"
if [[ -z "$PORT" ]]; then
    PORT=$((DEFAULT_BASE_PORT + RANDOM % PORT_RANGE))
fi

echo "🎯 TUIC 将使用端口: $PORT"

# 检测架构
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    BIN_URL="https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-x86_64-linux"
elif [[ "$ARCH" == "aarch64" ]]; then
    BIN_URL="https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-aarch64-linux"
else
    echo "❌ 不支持的 CPU 架构: $ARCH"
    exit 1
fi

# ---------------- 安装 TUIC ----------------
echo "⏳ 下载 TUIC: $BIN_URL"
curl -L -f -o "$TUIC_BIN" "$BIN_URL"
chmod +x "$TUIC_BIN"
echo "✅ TUIC 已安装: $TUIC_BIN"

# ---------------- 生成自签证书 ----------------
CERT_FILE="/etc/tuic-cert.pem"
KEY_FILE="/etc/tuic-key.pem"
if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
    echo "🔐 生成自签名证书 ($MASQ_DOMAIN)..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$KEY_FILE" -out "$CERT_FILE" -days 365 -nodes \
        -subj "/CN=${MASQ_DOMAIN}"
    chmod 600 "$KEY_FILE" 2>/dev/null || true
    chmod 644 "$CERT_FILE" 2>/dev/null || true
    echo "✅ 证书生成成功"
else
    echo "🔐 已检测到证书，跳过生成"
fi

# ---------------- 生成配置文件 ----------------
UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null)"
PASSWORD="$(openssl rand -hex 16)"

cat > "$SERVER_TOML" <<EOF
log_level = "off"
server = "0.0.0.0:${PORT}"

[users]
${UUID} = "${PASSWORD}"

[tls]
self_sign = false
certificate = "$CERT_FILE"
private_key = "$KEY_FILE"
alpn = ["h3"]

[restful]
addr = "127.0.0.1:${PORT}"
secret = "$(openssl rand -hex 16)"
maximum_clients_per_user = 999999999

[quic]
initial_mtu = 1500
min_mtu = 1200
gso = true
pmtu = true
send_window = 33554432
receive_window = 16777216
max_idle_time = "20s"

[quic.congestion_control]
controller = "bbr"
initial_window = 4194304
EOF

echo "✅ TUIC 配置已生成: $SERVER_TOML (端口 $PORT)"

# ---------------- 创建 systemd 或 OpenRC 服务 ----------------
if command -v systemctl &>/dev/null; then
    echo "⏳ 创建 systemd 服务..."
    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=TUIC Server
After=network.target
