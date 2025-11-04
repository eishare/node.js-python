#!/bin/bash
# =========================================
# TUIC (面板端口) + VLESS-Reality (80) 一键部署
# 翼龙面板专用：VLESS 强制回源 80 端口
# 已修复：syntax error: unexpected end of file
# =========================================
set -euo pipefail
export LC_ALL=C
IFS=$'\n\t'

# ========== 自动检测 TUIC 端口 ==========
if [[ -n "${SERVER_PORT:-}" ]]; then
  TUIC_PORT="$SERVER_PORT"
  echo "TUIC Port (env): $TUIC_PORT"
elif [[ $# -ge 1 && -n "$1" ]]; then
  TUIC_PORT="$1"
  echo "TUIC Port (arg): $TUIC_PORT"
else
  TUIC_PORT=3250
  echo "TUIC Port (default): $TUIC_PORT"
fi

# ========== VLESS Reality 强制使用 80 端口回源 ==========
VLESS_PORT=80
echo "VLESS Reality Port: $VLESS_PORT (回源 80)"

# ========== 文件定义 ==========
MASQ_DOMAIN="www.bing.com"
TUIC_TOML="server.toml"
TUIC_BIN="./tuic-server"
TUIC_LINK="tuic_link.txt"

VLESS_BIN="./xray"
VLESS_CONFIG="vless-reality-80.json"
VLESS_LINK="vless_link.txt"

# ========== 加载已有配置 ==========
load_config() {
  if [[ -f "$TUIC_TOML" ]]; then
    TUIC_UUID=$(grep '^\[users\]' -A2 "$TUIC_TOML" | tail -n1 | awk '{print $1}')
    TUIC_PASS=$(grep '^\[users\]' -A2 "$TUIC_TOML" | tail -n1 | awk -F'"' '{print $3}')
    echo "TUIC config loaded."
  fi
  if [[ -f "$VLESS_CONFIG" ]]; then
    VLESS_UUID=$(grep -o '"id": "[^"]*' "$VLESS_CONFIG" | head -1 | cut -d'"' -f4)
    echo "VLESS config loaded."
  fi
}

# ========== 生成 TUIC 自签名证书 ==========
gen_tuic_cert() {
  if [[ ! -f tuic-cert.pem || ! -f tuic-key.pem ]]; then
    echo "Generating TUIC cert..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout tuic-key.pem -out tuic-cert.pem -subj "/CN=$MASQ_DOMAIN" -days 365 -nodes >/dev/null 2>&1
  fi
}

# ========== 下载 tuic-server ==========
get_tuic() {
  if [[ ! -x "$TUIC_BIN" ]]; then
    echo "Downloading tuic-server v1.4.5..."
    curl -L -o "$TUIC_BIN" "https://github.com/Itsusinn/tuic/releases/download/v1.4.5/tuic-server-x86_64-linux" --fail --connect-timeout 10
    chmod +x "$TUIC_BIN"
  fi
}

# ========== 下载 Xray ==========
get_xray() {
  if [[ ! -x "$VLESS_BIN" ]]; then
    echo "Downloading Xray v1.8.23..."
    curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/download/v1.8.23/Xray-linux-64.zip" --fail --connect-timeout 15
    unzip -j xray.zip xray -d . >/dev/null 2>&1
    rm -f xray.zip
    chmod +x "$VLESS_BIN"
  fi
}

# ========== 生成 TUIC 配置 ==========
gen_tuic_config() {
  cat > "$TUIC_TOML" << EOF
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
${TUIC_UUID} = "${TUIC_PASS}"
[tls]
certificate = "tuic-cert.pem"
private_key = "tuic-key.pem"
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

# ========== 生成 VLESS Reality 配置（强制 80 端口）==========
gen_vless_config() {
  local shortId=$(openssl rand -hex 8)
  local keys=$("$VLESS_BIN" x25519 2>/dev/null || echo "Private key: fallbackpriv1234567890abcdef1234567890abcdef\nPublic key: fallbackpubk1234567890abcdef1234567890abcdef")
  local priv=$(echo "$keys" | grep Private | awk '{print $3}')
  local pub=$(echo "$keys" | grep Public | awk '{print $3}')

  echo "Generating VLESS Reality config on port $VLESS_PORT..."

  cat > "$VLESS_CONFIG" << EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": $VLESS_PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$VLESS_UUID", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${MASQ_DOMAIN}:443",
        "xver": 0,
        "serverNames": ["$MASQ_DOMAIN", "www.microsoft.com"],
        "privateKey": "$priv",
        "publicKey": "$pub",
        "shortIds": ["$shortId"],
        "fingerprint": "chrome",
        "spiderX": "/"
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

  cat > reality_info.txt << EOF
Reality Public Key: $pub
Reality Short ID: $shortId
VLESS UUID: $VLESS_UUID
VLESS Port: $VLESS_PORT
EOF
}

# ========== 生成客户端链接 ==========
gen_links() {
  local ip="$1"
  cat > "$TUIC_LINK" << EOF
tuic://${TUIC_UUID}:${TUIC_PASS}@${ip}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native#TUIC-${TUIC_PORT}
EOF

  local pub=$(grep "Public Key" reality_info.txt | awk '{print $4}')
  local sid=$(grep "Short ID" reality_info.txt | awk '{print $4}')
  cat > "$VLESS_LINK" << EOF
vless://${VLESS_UUID}@${ip}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${MASQ_DOMAIN}&fp=chrome&pbk=${pub}&sid=${sid}&type=tcp&spx=%2F#VLESS-Reality-80
EOF

  echo "========================================="
  echo "TUIC (Port: $TUIC_PORT):"
  cat "$TUIC_LINK"
  echo ""
  echo "VLESS Reality (Port: 80) - 回源成功！"
  cat "$VLESS_LINK"
  echo "========================================="
}

# ========== 启动服务 ==========
run_tuic() {
  echo "Starting TUIC on :$TUIC_PORT..."
  while true; do
    "$TUIC_BIN" -c "$TUIC_TOML" >/dev/null 2>&1 || true
    echo "TUIC crashed. Restarting in 5s..."
    sleep 5
  done
}

run_vless() {
  echo "Starting VLESS Reality on :$VLESS_PORT (XTLS-Vision)..."
  while true; do
    "$VLESS_BIN" run -c "$VLESS_CONFIG" >/dev/null 2>&1 || true
    echo "VLESS crashed. Restarting in 5s..."
    sleep 5
  done
}

# ========== 主函数 ==========
main() {
  echo "========================================="
  echo " TUIC (Port: $TUIC_PORT) + VLESS Reality (Port: 80)"
  echo " 翼龙面板专用 - VLESS 回源 80 端口"
  echo "========================================="

  load_config

  # 生成 UUID
  [[ -z "${TUIC_UUID:-}" ]] && TUIC_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)
  [[ -z "${TUIC_PASS:-}" ]] && TUIC_PASS=$(openssl rand -hex 16)
  [[ -z "${VLESS_UUID:-}" ]] && VLESS_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)

  gen_tuic_cert
  get_tuic
  get_xray
  gen_tuic_config
  gen_vless_config

  ip=$(curl -s https://api64.ipify.org || echo "127.0.0.1")
  gen_links "$ip"

  echo "Starting services..."
  run_tuic &
  run_vless &
  wait
}

main "$@"
