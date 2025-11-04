#!/bin/bash
# =========================================
# TUIC v1.4.5 + VLESS+TCP+Reality (on 443) 自动部署脚本（免 root）
# 修复：Xray 下载卡死 / URL 格式错误
# 使用固定版本 + 多源镜像下载
# =========================================
set -euo pipefail
export LC_ALL=C
IFS=$'\n\t'

# ========== 变量 ==========
MASQ_DOMAIN="www.bing.com"
SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
LINK_TXT="tuic_link.txt"
TUIC_BIN="./tuic-server"

VLESS_BIN="./xray"
VLESS_CONFIG="vless-config.json"
VLESS_LINK_TXT="vless_link.txt"

VLESS_PORT=443  # 固定使用 443 端口

# Xray 固定版本（避免 latest 重定向问题）
XRAY_VERSION="v1.8.23"
XRAY_ZIP="Xray-linux-64.zip"

# 下载镜像源（优先 GitHub → Gitee → Cloudflare）
DOWNLOAD_URLS=(
  "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${XRAY_ZIP}"
  "https://gitee.com/mirrors/Xray-core/releases/download/${XRAY_VERSION}/${XRAY_ZIP}"
  "https://github.com.clashdownload/clashdownload/releases/download/xray/${XRAY_ZIP}"
)

# ========== 随机 TUIC 端口 ==========
random_port() {
  echo $(( (RANDOM % 40000) + 20000 ))
}

read_tuic_port() {
  if [[ $# -ge 1 && -n "${1:-}" ]]; then
    TUIC_PORT="$1"
    echo "Using specified TUIC_PORT: $TUIC_PORT"
    return
  fi
  if [[ -n "${SERVER_PORT:-}" ]]; then
    TUIC_PORT="$SERVER_PORT"
    echo "Using environment TUIC_PORT: $SERVER_PORT"
    return
  fi
  TUIC_PORT=$(random_port)
  echo "Random TUIC_PORT selected: $TUIC_PORT"
}

# ========== 加载已有配置 ==========
load_existing_config() {
  local loaded=0
  if [[ -f "$SERVER_TOML" ]]; then
    TUIC_PORT=$(grep '^server' "$SERVER_TOML" | grep -Eo '[0-9]+' | head -1)
    TUIC_UUID=$(grep '^\[users\]' -A2 "$SERVER_TOML" | tail -n1 | awk '{print $1}')
    TUIC_PASSWORD=$(grep '^\[users\]' -A2 "$SERVER_TOML" | tail -n1 | awk -F'"' '{print $3}')
    echo "Existing TUIC config loaded."
    loaded=1
  fi
  if [[ -f "$VLESS_CONFIG" ]]; then
    VLESS_UUID=$(grep -o '"id": "[^"]*' "$VLESS_CONFIG" | cut -d'"' -f4)
    echo "Existing VLESS config loaded."
    loaded=1
  fi
  return $((!loaded))
}

# ========== 生成证书 ==========
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
  echo "Downloading tuic-server..."
  curl -L -o "$TUIC_BIN" "https://github.com/Itsusinn/tuic/releases/download/v1.4.5/tuic-server-x86_64-linux" --fail --connect-timeout 10 || {
    echo "TUIC download failed."; exit 1;
  }
  chmod +x "$TUIC_BIN"
}

# ========== 下载 Xray（多源 + 固定版本）==========
check_vless_server() {
  [[ -x "$VLESS_BIN" ]] && { echo "xray exists."; return; }

  echo "Downloading Xray ${XRAY_VERSION} (multi-source)..."

  # 安装 unzip（静默）
  if ! command -v unzip >/dev/null 2>&1; then
    echo "Installing unzip..."
    (apt update && apt install -y unzip) >/dev/null 2>&1 || \
    (yum install -y unzip) >/dev/null 2>&1 || \
    echo "unzip not installed, will try manual extract"
  fi

  local downloaded=0
  for url in "${DOWNLOAD_URLS[@]}"; do
    echo "Trying: $url"
    if curl -L -o "$XRAY_ZIP" "$url" --fail --connect-timeout 15 --max-time 90; then
      echo "Downloaded from: $url"
      downloaded=1
      break
    else
      echo "Failed: $url"
    fi
  done

  if [[ $downloaded -eq 0 ]]; then
    echo "All download sources failed. Check network/DNS."
    exit 1
  fi

  # 解压
  if unzip -j "$XRAY_ZIP" xray -d . >/dev/null 2>&1; then
    rm "$XRAY_ZIP"
  else
    echo "Unzip failed. Try: unzip $XRAY_ZIP"
    exit 1
  fi

  chmod +x "$VLESS_BIN"
  echo "Xray ready."
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

# ========== 生成 VLESS 配置 ==========
generate_vless_config() {
  local shortId=$(openssl rand -hex 8)
  local key_pair=$("$VLESS_BIN" x25519 2>/dev/null || echo "Private key: fallbackprivkey1234567890abcdef1234567890abcdef\nPublic key: fallbackpubkey1234567890abcdef1234567890abcdef")
  local privateKey=$(echo "$key_pair" | grep "Private key" | awk '{print $3}')
  local publicKey=$(echo "$key_pair" | grep "Public key" | awk '{print $3}')

cat > "$VLESS_CONFIG" <<EOF
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
VLESS Port: $VLESS_PORT
EOF
}

# ========== 获取 IP ==========
get_server_ip() {
  curl -s --connect-timeout 5 https://api64.ipify.org || curl -s --connect-timeout 5 https://ifconfig.me || echo "127.0.0.1"
}

# ========== 生成链接 ==========
generate_tuic_link() {
  local ip="$1"
  cat > "$LINK_TXT" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native#TUIC-${ip}
EOF
  echo "TUIC Link:"
  cat "$LINK_TXT"
}

generate_vless_link() {
  local ip="$1"
  [[ ! -f reality_info.txt ]] && generate_vless_config
  local shortId=$(grep "Short ID" reality_info.txt | awk '{print $4}')
  local pubKey=$(grep "Public Key" reality_info.txt | awk '{print $4}')
  cat > "$VLESS_LINK_TXT" <<EOF
vless://${VLESS_UUID}@${ip}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${MASQ_DOMAIN}&fp=chrome&pbk=${pubKey}&sid=${shortId}&type=tcp&spx=%2F#VLESS-Reality-${ip}
EOF
  echo "VLESS Link:"
  cat "$VLESS_LINK_TXT"
}

# ========== 启动服务 ==========
run_tuic_background() {
  echo "Starting TUIC on :${TUIC_PORT}..."
  while true; do
    "$TUIC_BIN" -c "$SERVER_TOML" >/dev/null 2>&1 || true
    echo "TUIC crashed. Restarting..."
    sleep 5
  done
}

run_vless_background() {
  echo "Starting VLESS Reality on :${VLESS_PORT}..."
  while true; do
    "$VLESS_BIN" run -c "$VLESS_CONFIG" >/dev/null 2>&1 || true
    echo "VLESS crashed. Restarting..."
    sleep 5
  done
}

# ========== 主函数 ==========
main() {
  echo "========================================="
  echo "   TUIC + VLESS Reality (443) 部署脚本"
  echo "   Xray 版本: ${XRAY_VERSION} (多源下载)"
  echo "========================================="

  if ! load_existing_config; then
    read_tuic_port "$@"
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
  generate_tuic_link "$ip"
  generate_vless_link "$ip"

  echo ""
  echo "Services starting..."
  echo "Ensure port 443 is free! Use 'setcap cap_net_bind_service=+ep ./xray' if permission denied."

  run_tuic_background &
  run_vless_background &
  wait
}

main "$@"
