#!/bin/bash
# =========================================
# TUIC v1.4.5 + VLESS 自动部署脚本（免 root）
# Tuic 使用随机端口，VLESS 使用 443 端口
# 固定 SNI：www.bing.com
# =========================================
set -euo pipefail
export LC_ALL=C
IFS=$'\n\t'

MASQ_DOMAIN="www.bing.com"
TUIC_TOML="tuic-server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
TUIC_BIN="./tuic-server"
TUIC_LINK="tuic_link.txt"

VLESS_DIR="$HOME/vless"
VLESS_BIN="$VLESS_DIR/xray"
VLESS_CONF="$VLESS_DIR/config.json"
VLESS_PORT=443

# ========== 随机端口 ==========
random_port() {
  echo $(( (RANDOM % 40000) + 20000 ))
}

# ========== 检测 Node.js ==========
check_node() {
  if ! command -v node &>/dev/null; then
    echo "❌ Node.js 未安装，请先安装 Node.js"
    exit 1
  fi
}

# ========== 检查并生成证书 ==========
generate_cert() {
  if [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]]; then
    echo "🔐 证书已存在，跳过生成"
    return
  fi
  echo "🔐 生成自签名证书..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
  chmod 600 "$KEY_PEM"
  chmod 644 "$CERT_PEM"
}

# ========== 下载 TUIC ==========
check_tuic_server() {
  if [[ -x "$TUIC_BIN" ]]; then
    echo "✅ tuic-server 已存在"
    return
  fi
  echo "📥 下载 tuic-server..."
  curl -L -o "$TUIC_BIN" "https://github.com/Itsusinn/tuic/releases/download/v1.4.5/tuic-server-x86_64-linux"
  chmod +x "$TUIC_BIN"
}

# ========== 生成 TUIC 配置 ==========
generate_tuic_config() {
  TUIC_PORT=$(random_port)
  TUIC_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
  TUIC_PASSWORD="$(openssl rand -hex 16)"
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
certificate = "$CERT_PEM"
private_key = "$KEY_PEM"
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

# ========== 生成 TUIC 链接 ==========
generate_tuic_link() {
  local ip="$1"
  cat > "$TUIC_LINK" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${ip}
EOF
  echo "🔗 TUIC 链接生成成功:"
  cat "$TUIC_LINK"
}

# ========== VLESS 部署 ==========
deploy_vless() {
  mkdir -p "$VLESS_DIR" && cd "$VLESS_DIR"
  if [[ ! -x "$VLESS_BIN" ]]; then
    echo "📥 下载 Xray-core (VLESS)..."
    curl -L -o xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/xray-linux-64.zip
    unzip -o xray.zip >/dev/null 2>&1
    chmod +x xray
    rm -f xray.zip
  fi
  UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
  cat > "$VLESS_CONF" <<EOF
{
  "inbounds":[
    {
      "port":$VLESS_PORT,
      "protocol":"vless",
      "settings":{
        "clients":[{"id":"$UUID"}],
        "decryption":"none"
      },
      "streamSettings":{
        "network":"tcp",
        "security":"tls",
        "tlsSettings":{
          "certificates":[{"certificateFile":"$CERT_PEM","keyFile":"$KEY_PEM"}]
        }
      }
    }
  ],
  "outbounds":[{"protocol":"freedom"}]
}
EOF
  nohup "$VLESS_BIN" -config "$VLESS_CONF" >/dev/null 2>&1 &
  echo "✅ VLESS 已启动 (443端口)，UUID: $UUID"
}

# ========== 获取公网 IP ==========
get_server_ip() {
  curl -s --connect-timeout 3 https://api64.ipify.org || echo "127.0.0.1"
}

# ========== 启动 TUIC 守护进程 ==========
run_tuic_loop() {
  echo "🚀 启动 TUIC 服务..."
  while true; do
    "$TUIC_BIN" -c "$TUIC_TOML" >/dev/null 2>&1 || true
    echo "⚠️ TUIC 崩溃，5秒后重启..."
    sleep 5
  done
}

# ========== 主流程 ==========
main() {
  check_node
  generate_cert
  check_tuic_server
  generate_tuic_config

  deploy_vless

  ip="$(get_server_ip)"
  generate_tuic_link "$ip"
  run_tuic_loop
}

main "$@"
