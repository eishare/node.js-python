#!/bin/bash
# =========================================
# TUIC + VLESS-WS-TLS 共用端口部署脚本（翼龙专用）
# TUIC: 原生 QUIC
# VLESS: WebSocket + TLS 伪装 HTTPS
# 共用端口 3250，零冲突
# =========================================
set -euo pipefail
export LC_ALL=C
IFS=$'\n\t'

# ========== 变量 ==========
MASQ_DOMAIN="www.bing.com"
SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
TUIC_LINK="tuic_link.txt"
TUIC_BIN="./tuic-server"

VLESS_BIN="./xray"
VLESS_CONFIG="vless-ws-tls.json"
VLESS_LINK="vless_ws_tls.txt"

# 共用端口
PORT="${SERVER_PORT:-${1:-3250}}"
echo "Using port: $PORT"

# VLESS WS 路径（用于区分流量）
WS_PATH="/$(openssl rand -hex 8)"

# ========== 加载配置 ==========
load_existing_config() {
  local loaded=0
  if [[ -f "$SERVER_TOML" ]]; then
  TUIC_UUID=$(grep '^\[users\]' -A2 "$SERVER_TOML" | tail -n1 | awk '{print $1}')
  TUIC_PASSWORD=$(grep '^\[users\]' -A2 "$SERVER_TOML" | tail -n1 | awk -F'"' '{print $3}')
  echo "TUIC config loaded."
  loaded=1
  fi
  if [[ -f "$VLESS_CONFIG" ]]; then
  VLESS_UUID=$(grep -o '"id": "[^"]*' "$VLESS_CONFIG" | head -1 | cut -d'"' -f4)
  WS_PATH=$(grep -o '/[a-f0-9]\{16\}' "$VLESS_CONFIG" || echo "$WS_PATH")
  echo "VLESS config loaded."
  loaded=1
  fi
  return $((!loaded))
}

# ========== 生成证书（TLS 用）==========
generate_cert() {
  [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]] && return
  echo "Generating TLS cert for $MASQ_DOMAIN..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
}

# ========== 下载 tuic-server ==========
check_tuic_server() {
  [[ -x "$TUIC_BIN" ]] && return
  echo "Downloading tuic-server..."
  curl -L -o "$TUIC_BIN" "https://github.com/Itsusinn/tuic/releases/download/v1.4.5/tuic-server-x86_64-linux" --fail --connect-timeout 10
  chmod +x "$TUIC_BIN"
}

# ========== 下载 Xray ==========
check_vless_server() {
  [[ -x "$VLESS_BIN" ]] && return
  echo "Downloading Xray..."
  local URLS=(
    "https://github.com/XTLS/Xray-core/releases/download/v1.8.23/Xray-linux-64.zip"
    "https://gitee.com/mirrors/Xray-core/releases/download/v1.8.23/Xray-linux-64.zip"
  )
  for url in "${URLS[@]}"; do
    curl -L -o xray.zip "$url" --fail --connect-timeout 15 --max-time 90 && break
  done
  unzip -j xray.zip xray -d . >/dev/null 2>&1 || { echo "unzip failed"; exit 1; }
  rm xray.zip
  chmod +x "$VLESS_BIN"
}

# ========== 生成 TUIC 配置 ==========
generate_tuic_config() {
cat > "$SERVER_TOML" <<EOF
log_level = "warn"
server = "0.0.0.0:${PORT}"
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
addr = "127.0.0.1:${PORT}"
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

# ========== 生成 VLESS-WS-TLS 配置 ==========
generate_vless_config() {
cat > "$VLESS_CONFIG" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$VLESS_UUID"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "tlsSettings": {
        "certificates": [{
          "certificateFile": "$CERT_PEM",
          "keyFile": "$KEY_PEM"
        }]
      },
      "wsSettings": {
        "path": "$WS_PATH"
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
}

# ========== 生成链接 ==========
generate_links() {
  local ip="$1"
  cat > "$TUIC_LINK" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native#TUIC-${ip}
EOF

  cat > "$VLESS_LINK" <<EOF
vless://${VLESS_UUID}@${ip}:${PORT}?encryption=none&security=tls&type=ws&host=${MASQ_DOMAIN}&path=${WS_PATH}#VLESS-WS-TLS-${ip}
EOF

  echo "Links:"
  echo "TUIC:"
  cat "$TUIC_LINK"
  echo "VLESS WS+TLS:"
  cat "$VLESS_LINK"
  echo "WS Path: $WS_PATH"
}

# ========== 启动 ==========
run_tuic() {
  echo "Starting TUIC on :$PORT..."
  while true; do
    "$TUIC_BIN" -c "$SERVER_TOML" >/dev/null 2>&1 || true
    echo "TUIC crashed. Restarting..."
    sleep 5
  done
}

run_vless() {
  echo "Starting VLESS WS+TLS on :$PORT (path: $WS_PATH)..."
  while true; do
    "$VLESS_BIN" run -c "$VLESS_CONFIG" >/dev/null 2>&1 || true
    echo "VLESS crashed. Restarting..."
    sleep 5
  done
}

# ========== 主函数 ==========
main() {
  echo "TUIC + VLESS-WS-TLS 共用端口 $PORT"

  if ! load_existing_config; then
    TUIC_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)
    TUIC_PASSWORD=$(openssl rand -hex 16)
    VLESS_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)
    generate_cert
    check_tuic_server
    check_vless_server
    generate_tuic_config
    generate_vless_config
  else
    generate_cert
    check_tuic_server
    check_vless_server
  fi

  ip=$(curl -s https://api64.ipify.org || echo "127.0.0.1")
  generate_links "$ip"

  run_tuic &
  run_vless &
  wait
}

main "$@"
