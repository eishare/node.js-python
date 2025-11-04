#!/bin/bash
# =========================================
# TUIC (面板端口) + VLESS-Reality (80) 一键部署
# 翼龙面板专用：VLESS 强制回源 80 端口
# 修复：卡死、语法错误、变量替换
# 使用 printf + 临时文件 + 防 set -e 崩溃
# =========================================
set -uo pipefail  # 移除 -e，避免 sed 失败退出

# ========== 自动检测 TUIC 端口 ==========
if [[ -n "${SERVER_PORT:-}" ]]; then
  TUIC_PORT="$SERVER_PORT"
elif [[ $# -ge 1 && -n "$1" ]]; then
  TUIC_PORT="$1"
else
  TUIC_PORT=3250
fi
echo "TUIC Port: $TUIC_PORT"

# ========== VLESS Reality 强制 80 端口 ==========
VLESS_PORT=80
echo "VLESS Reality Port: $VLESS_PORT"

# ========== 文件定义 ==========
MASQ_DOMAIN="www.bing.com"
TUIC_TOML="server.toml"
TUIC_BIN="./tuic-server"
TUIC_LINK="tuic_link.txt"
VLESS_BIN="./xray"
VLESS_CONFIG="vless-reality-80.json"
VLESS_LINK="vless_link.txt"

# ========== 加载配置 ==========
load_config() {
  TUIC_UUID=""
  TUIC_PASS=""
  VLESS_UUID=""

  if [[ -f "$TUIC_TOML" ]]; then
    TUIC_UUID=$(grep -A2 '^\[users\]' "$TUIC_TOML" | tail -n1 | awk '{print $1}' || echo "")
    TUIC_PASS=$(grep -A2 '^\[users\]' "$TUIC_TOML" | tail -n1 | awk -F'"' '{print $3}' || echo "")
  fi

  if [[ -f "$VLESS_CONFIG" ]]; then
    VLESS_UUID=$(grep -o '"id": "[^"]*' "$VLESS_CONFIG" | head -1 | cut -d'"' -f4 || echo "")
  fi
}

# ========== 生成证书 ==========
gen_cert() {
  [[ -f tuic-cert.pem && -f tuic-key.pem ]] && return
  echo "Generating cert..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout tuic-key.pem -out tuic-cert.pem -subj "/CN=$MASQ_DOMAIN" -days 365 -nodes >/dev/null 2>&1 || true
}

# ========== 下载 tuic-server ==========
get_tuic() {
  [[ -x "$TUIC_BIN" ]] && return
  echo "Downloading tuic-server..."
  curl -L -o "$TUIC_BIN" "https://github.com/Itsusinn/tuic/releases/download/v1.4.5/tuic-server-x86_64-linux" --fail --connect-timeout 10 || exit 1
  chmod +x "$TUIC_BIN"
}

# ========== 下载 Xray ==========
get_xray() {
  [[ -x "$VLESS_BIN" ]] && return
  echo "Downloading Xray..."
  curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/download/v1.8.23/Xray-linux-64.zip" --fail --connect-timeout 15 || exit 1
  unzip -j xray.zip xray -d . >/dev/null 2>&1 || exit 1
  rm -f xray.zip
  chmod +x "$VLESS_BIN"
}

# ========== 生成 TUIC 配置 ==========
gen_tuic_config() {
  local secret=$(openssl rand -hex 16)
  local mtu=$((1200 + RANDOM % 200))

  cat > "$TUIC_TOML" <<EOF
log_level = "warn"
server = "0.0.0.0:$TUIC_PORT"
udp_relay_ipv6 = false
zero_rtt_handshake = true
dual_stack = false
auth_timeout = "8s"
task_negotiation_timeout = "4s"
gc_interval = "8s"
gc_lifetime = "8s"
max_external_packet_size = 8192
[users]
$TUIC_UUID = "$TUIC_PASS"
[tls]
certificate = "tuic-cert.pem"
private_key = "tuic-key.pem"
alpn = ["h3"]
[restful]
addr = "127.0.0.1:$TUIC_PORT"
secret = "$secret"
maximum_clients_per_user = 999999999
[quic]
initial_mtu = $mtu
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
gen_vless_config() {
  local shortId=$(openssl rand -hex 8)
  local keys=$("$VLESS_BIN" x25519 2>/dev/null || echo "Private key: a\nPublic key: b")
  local priv=$(echo "$keys" | awk '/Private/ {print $3}')
  local pub=$(echo "$keys" | awk '/Public/ {print $3}')

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
        "dest": "$MASQ_DOMAIN:443",
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

  echo "Reality Public Key: $pub" > reality_info.txt
  echo "Reality Short ID: $shortId" >> reality_info.txt
  echo "VLESS UUID: $VLESS_UUID" >> reality_info.txt
  echo "VLESS Port: $VLESS_PORT" >> reality_info.txt
}

# ========== 生成链接 ==========
gen_links() {
  local ip="$1"
  local pub=$(grep "Public Key" reality_info.txt | awk '{print $4}')
  local sid=$(grep "Short ID" reality_info.txt | awk '{print $4}')

  printf "tuic://%s:%s@%s:%s?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=%s&udp_relay_mode=native#TUIC\n" \
    "$TUIC_UUID" "$TUIC_PASS" "$ip" "$TUIC_PORT" "$MASQ_DOMAIN" > "$TUIC_LINK"

  printf "vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&spx=/#VLESS-Reality-80\n" \
    "$VLESS_UUID" "$ip" "$VLESS_PORT" "$MASQ_DOMAIN" "$pub" "$sid" > "$VLESS_LINK"

  echo "========================================="
  echo "TUIC Link:"
  cat "$TUIC_LINK"
  echo "VLESS Link:"
  cat "$VLESS_LINK"
  echo "========================================="
}

# ========== 启动 ==========
run_tuic() {
  echo "Starting TUIC..."
  while :; do
    "$TUIC_BIN" -c "$TUIC_TOML" >/dev/null 2>&1 || sleep 5
  done &
}

run_vless() {
  echo "Starting VLESS Reality..."
  while :; do
    "$VLESS_BIN" run -c "$VLESS_CONFIG" >/dev/null 2>&1 || sleep 5
  done &
}

# ========== 主函数 ==========
main() {
  load_config

  # 生成 UUID
  [[ -z "$TUIC_UUID" ]] && TUIC_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)
  [[ -z "$TUIC_PASS" ]] && TUIC_PASS=$(openssl rand -hex 16)
  [[ -z "$VLESS_UUID" ]] && VLESS_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)

  gen_cert
  get_tuic
  get_xray
  gen_tuic_config
  gen_vless_config

  ip=$(curl -s https://api64.ipify.org || echo "127.0.0.1")
  gen_links "$ip"

  run_tuic
  run_vless
  wait
}

# ========== 执行 ==========
main "$@"
