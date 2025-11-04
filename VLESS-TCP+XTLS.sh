#!/bin/bash
# =========================================
# TUIC v1.4.5 + VLESS TCP+XTLS 自动部署脚本（Node.js 容器适用）
# TUIC：自动检测UDP端口
# VLESS：固定443端口
# =========================================

set -euo pipefail
export LC_ALL=C
IFS=$'\n\t'

########################
# ===== TUIC 配置 =====
########################
MASQ_DOMAIN="www.bing.com"
TUIC_TOML="server.toml"
TUIC_CERT="tuic-cert.pem"
TUIC_KEY="tuic-key.pem"
TUIC_LINK="tuic_link.txt"
TUIC_BIN="./tuic-server"

random_port() { echo $(( (RANDOM % 40000) + 20000 )); }

read_tuic_port() {
  if [[ -n "${SERVER_PORT:-}" ]]; then
    TUIC_PORT="$SERVER_PORT"
    echo "✅ 使用环境端口: $TUIC_PORT"
  else
    TUIC_PORT=$(random_port)
    echo "🎲 TUIC 随机UDP端口: $TUIC_PORT"
  fi
}

generate_tuic_cert() {
  if [[ ! -f "$TUIC_CERT" || ! -f "$TUIC_KEY" ]]; then
    echo "🔐 生成 TUIC 自签证书..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "$TUIC_KEY" -out "$TUIC_CERT" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
    chmod 600 "$TUIC_KEY" && chmod 644 "$TUIC_CERT"
  fi
}

check_tuic() {
  if [[ ! -x "$TUIC_BIN" ]]; then
    echo "📥 下载 TUIC..."
    curl -L -o "$TUIC_BIN" "https://github.com/Itsusinn/tuic/releases/download/v1.4.5/tuic-server-x86_64-linux"
    chmod +x "$TUIC_BIN"
  fi
}

generate_tuic_config() {
cat > "$TUIC_TOML" <<EOF
log_level = "warn"
server = "0.0.0.0:${TUIC_PORT}"

udp_relay_ipv6 = false
zero_rtt_handshake = true
dual_stack = false
auth_timeout = "8s"
task_negotiation_timeout = "4s"
gc_interval = "8s"
gc_lifetime = "8s"
max_external_packet_size = 8192

[users]
${TUIC_UUID} = "${TUIC_PASSWORD}"

[tls]
certificate = "$TUIC_CERT"
private_key = "$TUIC_KEY"
alpn = ["h3"]

[restful]
addr = "127.0.0.1:${TUIC_PORT}"
secret = "$(openssl rand -hex 16)"
maximum_clients_per_user = 999999999

[quic]
initial_mtu = $((1200 + RANDOM % 200))
min_mtu = 1200
gso = true
pmtu = true
send_window = 33554432
receive_window = 16777216
max_idle_time = "25s"

[quic.congestion_control]
controller = "bbr"
initial_window = 6291456
EOF
}

generate_tuic_link() {
  local ip="$1"
  cat > "$TUIC_LINK" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${ip}
EOF
  echo "🔗 TUIC 链接:"
  cat "$TUIC_LINK"
}

run_tuic() {
  echo "🚀 启动 TUIC..."
  while true; do
    "$TUIC_BIN" -c "$TUIC_TOML" >/dev/null 2>&1 || true
    echo "⚠️ TUIC 崩溃，5秒后重启..."
    sleep 5
  done
}

########################
# ===== VLESS 配置 =====
########################
XRAY_VER="v25.10.15"
XRAY_BIN="./xray"
XRAY_CONF="./xray.json"
CERT_DIR="./vless_cert"

mkdir -p "$CERT_DIR"

generate_vless_cert() {
  if [[ ! -f "$CERT_DIR/cert.pem" || ! -f "$CERT_DIR/private.key" ]]; then
    echo "🔐 生成 VLESS 自签证书..."
    openssl req -x509 -newkey rsa:2048 -keyout "$CERT_DIR/private.key" -out "$CERT_DIR/cert.pem" \
      -days 365 -nodes -subj "/CN=${MASQ_DOMAIN}" >/dev/null 2>&1
  fi
}

check_xray() {
  if [[ ! -x "$XRAY_BIN" ]]; then
    echo "📥 下载 Xray-core v${XRAY_VER}..."
    curl -L -o xray.tgz "https://ghproxy.net/https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/Xray-linux-64.tar.gz"
    tar -xzf xray.tgz xray >/dev/null 2>&1
    chmod +x xray
    rm -f xray.tgz
  fi
}

generate_vless_config() {
cat > "$XRAY_CONF" <<EOF
{
  "inbounds": [{
    "port": 443,
    "listen": "0.0.0.0",
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${VLESS_UUID}"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "xtls",
      "xtlsSettings": {
        "serverName": "${MASQ_DOMAIN}",
        "alpn": ["http/1.1"],
        "certificates": [{
          "certificateFile": "${CERT_DIR}/cert.pem",
          "keyFile": "${CERT_DIR}/private.key"
        }]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
}

generate_vless_link() {
  SERVER_IP=$(curl -s https://api64.ipify.org || echo "127.0.0.1")
  VLESS_LINK="vless://${VLESS_UUID}@${SERVER_IP}:443?security=xtls&encryption=none&flow=xtls-rprx-vision&tls=xtls&sni=${MASQ_DOMAIN}#VLESS-${SERVER_IP}"
  echo "🔗 VLESS 链接:"
  echo "$VLESS_LINK"
}

run_vless() {
  echo "🚀 启动 VLESS..."
  "$XRAY_BIN" run -c "$XRAY_CONF" >/dev/null 2>&1 &
}

########################
# ===== 主流程 =====
########################
main() {
  # TUIC
  read_tuic_port
  TUIC_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
  TUIC_PASSWORD="$(openssl rand -hex 16)"
  generate_tuic_cert
  check_tuic
  generate_tuic_config
  IP=$(curl -s https://api64.ipify.org || echo "127.0.0.1")
  generate_tuic_link "$IP"

  # VLESS
  VLESS_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
  generate_vless_cert
  check_xray
  generate_vless_config
  generate_vless_link

  # 启动服务
  run_vless
  run_tuic
  wait
}

main "$@"
