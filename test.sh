#!/bin/bash
# =========================================
# TUIC v1.4.5 + VLESS+TCP+Reality 自动部署脚本（免 root）
# TUIC SNI: www.bing.com
# VLESS Reality: fallback to /, shortId, serverNames, 固定监听 443 端口
# =========================================
set -euo pipefail
export LC_ALL=C
IFS=$'\n\t'

# ========== 通用变量 ==========
MASQ_DOMAIN="www.bing.com"
SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
LINK_TXT="tuic_link.txt"
TUIC_BIN="./tuic-server"

VLESS_BIN="./xray"
VLESS_CONFIG="vless-config.json"
VLESS_LINK_TXT="vless_link.txt"

# VLESS 固定端口 443（服务器自身通信端口）
VLESS_PORT=443

# ========== 随机端口（仅 TUIC）==========
random_port() {
  echo $(( (RANDOM % 40000) + 20000 ))
}

# ========== 选择 TUIC 端口 ==========
read_tuic_port() {
  if [[ $# -ge 1 && -n "${1:-}" ]]; then
    TUIC_PORT="$1"
    echo "✅ Using specified TUIC_PORT: $TUIC_PORT"
    return
  fi
  if [[ -n "${SERVER_PORT:-}" ]]; then
    TUIC_PORT="$SERVER_PORT"
    echo "✅ Using environment TUIC_PORT: $SERVER_PORT"
    return
  fi
  TUIC_PORT=$(random_port)
  echo "🎲 Random TUIC_PORT selected: $TUIC_PORT"
}

# ========== 检查已有配置 ==========
load_existing_config() {
  local loaded=0

  # TUIC
  if [[ -f "$SERVER_TOML" ]]; then
    TUIC_PORT=$(grep '^server' "$SERVER_TOML" | grep -Eo '[0-9]+' | head -1)
    TUIC_UUID=$(grep '^\[users\]' -A2 "$SERVER_TOML" | tail -n1 | awk '{print $1}')
    TUIC_PASSWORD=$(grep '^\[users\]' -A2 "$SERVER_TOML" | tail -n1 | awk -F'"' '{print $3}')
    echo "📂 Existing TUIC config loaded."
    loaded=1
  fi

  # VLESS
  if [[ -f "$VLESS_CONFIG" ]]; then
    VLESS_UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$VLESS_CONFIG")
    echo "📂 Existing VLESS config loaded."
    loaded=1
  fi

  return $((!loaded))
}

# ========== 生成自签名证书（TUIC）==========
generate_cert() {
  if [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]]; then
    echo "🔐 TUIC certificate exists, skipping."
    return
  fi
  echo "🔐 Generating self-signed certificate for ${MASQ_DOMAIN}..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
  chmod 600 "$KEY_PEM"
  chmod 644 "$CERT_PEM"
}

# ========== 下载 tuic-server ==========
check_tuic_server() {
  if [[ -x "$TUIC_BIN" ]]; then
    echo "✅ tuic-server already exists."
    return
  fi
  echo "📥 Downloading tuic-server v1.4.5..."
  curl -L -o "$TUIC_BIN" "https://github.com/Itsusinn/tuic/releases/download/v1.4.5/tuic-server-x86_64-linux"
  chmod +x "$TUIC_BIN"
}

# ========== 下载 Xray (VLESS) ==========
check_vless_server() {
  if [[ -x "$VLESS_BIN" ]]; then
    echo "✅ xray already exists."
    return
  fi
  echo "📥 Downloading latest Xray Linux 64-bit..."
  local api_url="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
  local latest_tag=$(curl -s "$api_url" | grep '"tag_name"' | cut -d'"' -f4)
  if [[ -z "$latest_tag" ]]; then
    echo "❌ Failed to get latest Xray version. Falling back to v1.8.20."
    latest_tag="v1.8.20"
  fi
  local download_url="https://github.com/XTLS/Xray-core/releases/download/${latest_tag}/Xray-linux-64.zip"
  curl -L -o xray.zip "$download_url"
  unzip -j xray.zip xray -d .
  rm xray.zip
  chmod +x "$VLESS_BIN"
}

# ========== 生成 TUIC 配置 ==========
generate_tuic_config() {
cat > "$SERVER_TOML" <<EOF
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

# ========== 生成 VLESS Reality 配置 ==========
generate_vless_config() {
  local shortId=$(openssl rand -hex 8)
  local keypair=$("$VLESS_BIN" x25519)
  local privateKey=$(echo "$keypair" | grep "Private key" | awk '{print $3}')
  local publicKey=$(echo "$keypair" | grep "Public key" | awk '{print $3}')

cat > "$VLESS_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $VLESS_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$VLESS_UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${MASQ_DOMAIN}:443",
          "xver": 0,
          "serverNames": [
            "${MASQ_DOMAIN}",
            "www.microsoft.com",
            "login.microsoftonline.com"
          ],
          "privateKey": "$privateKey",
          "publicKey": "$publicKey",
          "minClientVer": "",
          "maxClientVer": "",
          "maxTimeDiff": 0,
          "shortIds": [
            "$shortId"
          ],
          "fingerprint": "chrome",
          "spiderX": "/"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

  # 保存 Reality 信息
  cat > reality_info.txt <<EOF
Reality Public Key: $publicKey
Reality Short ID: $shortId
VLESS UUID: $VLESS_UUID
VLESS Port: $VLESS_PORT (固定服务器443端口)
EOF
}

# ========== 获取公网IP ==========
get_server_ip() {
  curl -s --connect-timeout 3 https://api64.ipify.org || echo "127.0.0.1"
}

# ========== 生成 TUIC 链接 ==========
generate_tuic_link() {
  local ip="$1"
  cat > "$LINK_TXT" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${ip}
EOF
  echo "🔗 TUIC link generated:"
  cat "$LINK_TXT"
}

# ========== 生成 VLESS Reality 链接 ==========
generate_vless_link() {
  local ip="$1"
  local shortId=$(grep "Short ID" reality_info.txt | awk '{print $4}')
  local pubKey=$(grep "Public Key" reality_info.txt | awk '{print $4}')
  cat > "$VLESS_LINK_TXT" <<EOF
vless://${VLESS_UUID}@${ip}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${MASQ_DOMAIN}&fp=chrome&pbk=${pubKey}&sid=${shortId}&type=tcp&spx=%2F#VLESS-Reality-${ip}
EOF
  echo "🔗 VLESS Reality link generated:"
  cat "$VLESS_LINK_TXT"
}

# ========== 守护进程：TUIC ==========
run_tuic_background() {
  echo "🚀 Starting TUIC server on :${TUIC_PORT}..."
  while true; do
    "$TUIC_BIN" -c "$SERVER_TOML" >/dev/null 2>&1 || true
    echo "⚠️ TUIC crashed. Restarting in 5s..."
    sleep 5
  done
}

# ========== 守护进程：VLESS ==========
run_vless_background() {
  echo "🚀 Starting VLESS Reality server on :${VLESS_PORT} (服务器443端口)..."
  while true; do
    "$VLESS_BIN" run -c "$VLESS_CONFIG" >/dev/null 2>&1 || true
    echo "⚠️ VLESS crashed. Restarting in 5s..."
    sleep 5
  done
}

# ========== 主流程 ==========
main() {
  echo "========================================="
  echo "   TUIC + VLESS Reality 一键部署脚本"
  echo "   VLESS 固定使用 443 端口"
  echo "========================================="

  if ! load_existing_config; then
    # 首次运行
    read_tuic_port "$@"

    TUIC_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
    TUIC_PASSWORD="$(openssl rand -hex 16)"
    VLESS_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"

    generate_cert
    check_tuic_server
    check_vless_server
    generate_tuic_config
    generate_vless_config
  else
    # 已有配置
    generate_cert
    check_tuic_server
    check_vless_server
    [[ ! -f "$SERVER_TOML" ]] && generate_tuic_config
    [[ ! -f "$VLESS_CONFIG" ]] && generate_vless_config
  fi

  ip="$(get_server_ip)"
  generate_tuic_link "$ip"
  generate_vless_link "$ip"

  echo ""
  echo "🚀 启动服务（TUIC on :${TUIC_PORT} + VLESS on :443）..."

  # 并行启动
  run_tuic_background &
  run_vless_background &
  wait
}

main "$@"
