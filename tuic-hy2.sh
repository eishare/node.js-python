#!/bin/sh
# TUIC v5 over QUIC 自动部署脚本（兼容 Alpine & Ubuntu/Debian）
# 极度精简版本

set -e
MASQ_DOMAIN="www.bing.com"
SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
LINK_TXT="tuic_link.txt"
TUIC_BIN="./tuic-server"

# ===================== 检查依赖 =====================
command -v curl >/dev/null 2>&1 || { echo "curl 未安装，正在安装..."; apk add --no-cache curl >/dev/null 2>&1 || apt -y install curl >/dev/null 2>&1; }
command -v openssl >/dev/null 2>&1 || { echo "openssl 未安装，正在安装..."; apk add --no-cache openssl >/dev/null 2>&1 || apt -y install openssl >/dev/null 2>&1; }
command -v uuidgen >/dev/null 2>&1 || { echo "uuidgen 未安装，正在安装..."; apk add --no-cache util-linux >/dev/null 2>&1 || apt -y install uuid-runtime >/dev/null 2>&1; }

# ===================== 端口/UUID/密码 =====================
read_port() {
  if [ -n "$1" ]; then
    TUIC_PORT="$1"
  elif [ -n "${SERVER_PORT:-}" ]; then
    TUIC_PORT="$SERVER_PORT"
  else
    TUIC_PORT=$(shuf -i2000-65535 -n1)
  fi
  echo "✅ TUIC端口: $TUIC_PORT"
}

load_existing_config() {
  if [ -f "$SERVER_TOML" ]; then
    TUIC_PORT=$(grep '^server =' "$SERVER_TOML" | sed -E 's/.*:(.*)\"/\1/')
    TUIC_UUID=$(grep '^\[users\]' -A1 "$SERVER_TOML" | tail -n1 | awk '{print $1}')
    TUIC_PASSWORD=$(grep '^\[users\]' -A1 "$SERVER_TOML" | tail -n1 | awk -F'"' '{print $2}')
    echo "📂 已加载配置: $TUIC_PORT / $TUIC_UUID / $TUIC_PASSWORD"
    return 0
  fi
  return 1
}

# ===================== 证书生成 =====================
generate_cert() {
  [ -f "$CERT_PEM" ] && [ -f "$KEY_PEM" ] && echo "🔐 已有证书，跳过生成" && return
  echo "🔐 生成自签 ECDSA-P256 证书..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
  chmod 600 "$KEY_PEM" && chmod 644 "$CERT_PEM"
  echo "✅ 自签证书生成完成"
}

# ===================== 下载 TUIC =====================
check_tuic_server() {
  [ -x "$TUIC_BIN" ] && echo "✅ 已存在 tuic-server" && return
  ARCH=$(uname -m)
  [ "$ARCH" != "x86_64" ] && echo "❌ 暂不支持架构: $ARCH" && exit 1
  echo "📥 下载 tuic-server..."
  TUIC_URL="https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-x86_64-linux"
  curl -L -f -o "$TUIC_BIN" "$TUIC_URL"
  chmod +x "$TUIC_BIN"
  echo "✅ tuic-server 下载完成"
}

# ===================== 生成配置 =====================
generate_config() {
cat > "$SERVER_TOML" <<EOF
log_level = "off"
server = "0.0.0.0:${TUIC_PORT}"

udp_relay_ipv6 = false
zero_rtt_handshake = true
dual_stack = false
auth_timeout = "10s"
task_negotiation_timeout = "5s"
gc_interval = "10s"
gc_lifetime = "10s"
max_external_packet_size = 8192

[users]
${TUIC_UUID} = "${TUIC_PASSWORD}"

[tls]
self_sign = false
certificate = "$CERT_PEM"
private_key = "$KEY_PEM"
alpn = ["h3"]

[restful]
addr = "127.0.0.1:${TUIC_PORT}"
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
}

# ===================== 获取公网IP =====================
get_server_ip() {
  curl -s --connect-timeout 3 https://api.ipify.org || echo "YOUR_SERVER_IP"
}

# ===================== 生成 TUIC 链接 =====================
generate_link() {
cat > "$LINK_TXT" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${1}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${1}
EOF
echo "📱 TUIC链接已生成: $LINK_TXT"
}

# ===================== 后台守护 =====================
run_background_loop() {
  echo "✅ TUIC 服务已启动..."
  while true; do
    "$TUIC_BIN" -c "$SERVER_TOML"
    echo "⚠️ tuic-server 已退出，5秒后重启..."
    sleep 5
  done
}

# ===================== 主逻辑 =====================
main() {
  if ! load_existing_config; then
    echo "⚙️ 第一次运行，初始化中..."
    read_port "$@"
    TUIC_UUID=$(uuidgen)
    TUIC_PASSWORD=$(openssl rand -hex 16)
    echo "🔑 UUID: $TUIC_UUID"
    echo "🔑 密码: $TUIC_PASSWORD"
    echo "🎯 SNI: $MASQ_DOMAIN"
    generate_cert
    check_tuic_server
    generate_config
  else
    generate_cert
    check_tuic_server
  fi
  IP=$(get_server_ip)
  generate_link "$IP"
  run_background_loop
}

main "$@"
