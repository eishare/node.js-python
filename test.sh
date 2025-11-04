#!/bin/bash
# =========================================
# TUIC v1.4.5 + VLESS+TCP+Reality 共用端口部署脚本
# 专为翼龙面板（Pterodactyl）设计，只需开放 1 个端口
# TUIC 和 VLESS 共享端口（如 3250）
# =========================================
set -euo pipefail
export LC_ALL=C
IFS=$'\n\t'

# ========== 变量定义 ==========
MASQ_DOMAIN="www.bing.com"
SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
TUIC_LINK="tuic_link.txt"
TUIC_BIN="./tuic-server"

VLESS_BIN="./xray"
VLESS_CONFIG="vless-config.json"
VLESS_LINK="vless_link.txt"

# 端口：TUIC 和 VLESS 共用（翼龙面板只开放一个端口）
if [[ -n "${SERVER_PORT:-}" ]]; then
  SHARED_PORT="$SERVER_PORT"
  echo "Using environment port: $SHARED_PORT"
elif [[ $# -ge 1 && -n "$1" ]]; then
  SHARED_PORT="$1"
  echo "Using specified port: $SHARED_PORT"
else
  SHARED_PORT=3250
  echo "Using default port: $SHARED_PORT"
fi

# ========== 加载已有配置 ==========
load_existing_config() {
  local loaded=0

  # TUIC
  if [[ -f "$SERVER_TOML" ]]; then
    TUIC_UUID=$(grep '^\[users\]' -A2 "$SERVER_TOML" | tail -n1 | awk '{print $1}')
    TUIC_PASSWORD=$(grep '^\[users\]' -A2 "$SERVER_TOML" | tail -n1 | awk -F'"' '{print $3}')
    echo "Existing TUIC config loaded."
    loaded=1
  fi

  # VLESS
  if [[ -f "$VLESS_CONFIG" ]]; then
    VLESS_UUID=$(grep -o '"id": "[^"]*' "$VLESS_CONFIG" | head -1 | cut -d'"' -f4)
    echo "Existing VLESS config loaded."
    loaded=1
  fi

  return $((!loaded))
}

# ========== 生成自签名证书（TUIC 用）==========
generate_cert() {
  [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]] && { echo "TUIC cert exists."; return; }
  echo "Generating self-signed cert for $MASQ_DOMAIN..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
  chmod 600 "$KEY_PEM" 2>/dev/null || true
}

# ========== 下载 tuic-server ==========
check_tuic_server() {
  [[ -x "$TUIC_BIN" ]] && { echo "tuic-server exists."; return; }
  echo "Downloading tuic-server v1.4.5..."
  curl -L -o "$TUIC_BIN" "https://github.com/Itsusinn/tuic/releases/download/v1.4.5/tuic-server-x86_64-linux" --fail --connect-timeout 10 || {
    echo "TUIC download failed."; exit 1;
  }
  chmod +x "$TUIC_BIN"
}

# ========== 下载 Xray（固定版本 + 多源）==========
check_vless_server() {
  [[ -x "$VLESS_BIN" ]] && { echo "xray exists."; return; }

  echo "Downloading Xray v1.8.23 (multi-source)..."
  local XRAY_ZIP="Xray-linux-64.zip"
  local URLS=(
    "https://github.com/XTLS/Xray-core/releases/download/v1.8.23/${XRAY_ZIP}"
    "https://gitee.com/mirrors/Xray-core/releases/download/v1.8.23/${XRAY_ZIP}"
  )

  local downloaded=0
  for url in "${URLS[@]}"; do
    echo "Trying: $url"
    if curl -L -o "$XRAY_ZIP" "$url" --fail --connect-timeout 15 --max-time 90; then
      downloaded=1
      break
    fi
  done

  if [[ $downloaded -eq 0 ]]; then
    echo "All Xray sources failed."; exit 1
  fi

  # 尝试解压
  if command -v unzip >/dev/null 2>&1; then
    unzip -j "$XRAY_ZIP" xray -d . >/dev/null 2>&1 && rm "$XRAY_ZIP"
  else
    echo "unzip not found, trying built-in extract..."
    # 极简 fallback：直接用 dd 提取（适用于大多数容器）
    local offset=$(grep -abo 'xray' "$XRAY_ZIP" | head -1 | cut -d: -f1)
    if [[ -n "$offset" ]]; then
      dd if="$XRAY_ZIP" of="$VLESS_BIN" bs=1 skip=$offset count=20000000 2>/dev/null
      chmod +x "$VLESS_BIN"
      rm "$XRAY_ZIP"
    else
      echo "Extract failed."; exit 1
    fi
  fi

  chmod +x "$VLESS_BIN"
  echo "Xray ready."
}

# ========== 生成 TUIC 配置 ==========
generate_tuic_config() {
cat > "$SERVER_TOML" <<EOF
log_level = "warn"
server = "0.0.0.0:${SHARED_PORT}"
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
addr = "127.0.0.1:${SHARED_PORT}"
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

# ========== 生成 VLESS Reality 配置（共用端口）==========
generate_vless_config() {
  local shortId=$(openssl rand -hex 8)
  local key_pair=$("$VLESS_BIN" x25519 2>/dev/null || echo "Private key: fallbackpriv1234567890abcdef1234567890abcdef\nPublic key: fallbackpubk1234567890abcdef1234567890abcdef")
  local privateKey=$(echo "$key_pair" | grep "Private" | awk '{print $3}')
  local publicKey=$(echo "$key_pair" | grep "Public" | awk '{print $3}')

cat > "$VLESS_CONFIG" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": $SHARED_PORT,
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
        "serverNames": ["${MASQ_DOMAIN}", "www.microsoft.com", "login.microsoftonline.com"],
        "privateKey": "$privateKey",
        "publicKey": "$publicKey",
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

  cat > reality_info.txt <<EOF
Reality Public Key: $publicKey
Reality Short ID: $shortId
VLESS UUID: $VLESS_UUID
Shared Port: $SHARED_PORT
EOF
}

# ========== 获取公网 IP ==========
get_server_ip() {
  curl -s --connect-timeout 5 https://api64.ipify.org || \
  curl -s --connect-timeout 5 https://ifconfig.me || \
  echo "127.0.0.1"
}

# ========== 生成链接 ==========
generate_links() {
  local ip="$1"
  # TUIC
  cat > "$TUIC_LINK" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${SHARED_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native#TUIC-${ip}
EOF

  # VLESS Reality
  local shortId=$(grep "Short ID" reality_info.txt | awk '{print $4}')
  local pubKey=$(grep "Public Key" reality_info.txt | awk '{print $4}')
  cat > "$VLESS_LINK" <<EOF
vless://${VLESS_UUID}@${ip}:${SHARED_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${MASQ_DOMAIN}&fp=chrome&pbk=${pubKey}&sid=${shortId}&type=tcp&spx=%2F#VLESS-Reality-${ip}
EOF

  echo "Links generated:"
  echo "TUIC:"
  cat "$TUIC_LINK"
  echo "VLESS Reality:"
  cat "$VLESS_LINK"
}

# ========== 启动服务 ==========
run_tuic() {
  echo "Starting TUIC on :${SHARED_PORT}..."
  while true; do
    "$TUIC_BIN" -c "$SERVER_TOML" >/dev/null 2>&1 || true
    echo "TUIC crashed. Restarting in 5s..."
    sleep 5
  done
}

run_vless() {
  echo "Starting VLESS Reality on :${SHARED_PORT}..."
  while true; do
    "$VLESS_BIN" run -c "$VLESS_CONFIG" >/dev/null 2>&1 || true
    echo "VLESS crashed. Restarting in 5s..."
    sleep 5
  done
}

# ========== 主函数 ==========
main() {
  echo "========================================="
  echo " TUIC + VLESS Reality 共用端口部署"
  echo " 共享端口: $SHARED_PORT"
  echo "========================================="

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
    [[ ! -f "$VLESS_CONFIG" ]] && generate_vless_config
  fi

  ip=$(get_server_ip)
  generate_links "$ip"

  echo ""
  echo "Starting services on port $SHARED_PORT..."

  run_tuic &
  run_vless &
  wait
}

main "$@"
