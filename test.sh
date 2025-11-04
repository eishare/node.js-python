#!/bin/bash
# =========================================
# TUIC (面板端口) + VLESS-Reality (80) 一键部署
# 翼龙面板专用：VLESS 强制回源 80 端口
# 修复：unexpected end of file
# 所有 EOF 独占一行 + 无缩进 + sed 安全替换
# =========================================
set -euo pipefail

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
  [[ -f "$TUIC_TOML" ]] && TUIC_UUID=$(awk '/^\[users\]/{getline; getline; print $1}' "$TUIC_TOML") && TUIC_PASS=$(awk '/^\[users\]/{getline; getline; gsub(/"/, "", $3); print $3}' "$TUIC_TOML")
  [[ -f "$VLESS_CONFIG" ]] && VLESS_UUID=$(grep -o '"id": "[^"]*' "$VLESS_CONFIG" | cut -d'"' -f4)
}

# ========== 生成证书 ==========
gen_cert() {
  [[ -f tuic-cert.pem && -f tuic-key.pem ]] && return
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout tuic-key.pem -out tuic-cert.pem -subj "/CN=$MASQ_DOMAIN" -days 365 -nodes >/dev/null 2>&1
}

# ========== 下载 tuic-server ==========
get_tuic() {
  [[ -x "$TUIC_BIN" ]] && return
  curl -L -o "$TUIC_BIN" "https://github.com/Itsusinn/tuic/releases/download/v1.4.5/tuic-server-x86_64-linux" --fail --connect-timeout 10
  chmod +x "$TUIC_BIN"
}

# ========== 下载 Xray ==========
get_xray() {
  [[ -x "$VLESS_BIN" ]] && return
  curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/download/v1.8.23/Xray-linux-64.zip" --fail --connect-timeout 15
  unzip -j xray.zip xray -d . >/dev/null 2>&1
  rm -f xray.zip
  chmod +x "$VLESS_BIN"
}

# ========== 生成 TUIC 配置 ==========
gen_tuic_config() {
cat > "$TUIC_TOML" <<'EOF'
log_level = "warn"
server = "0.0.0.0:__PORT__"
udp_relay_ipv6 = false
zero_rtt_handshake = true
dual_stack = false
auth_timeout = "8s"
task_negotiation_timeout = "4s"
gc_interval = "8s"
gc_lifetime = "8s"
max_external_packet_size = 8192
[users]
__UUID__ = "__PASS__"
[tls]
certificate = "tuic-cert.pem"
private_key = "tuic-key.pem"
alpn = ["h3"]
[restful]
addr = "127.0.0.1:__PORT__"
secret = "__SECRET__"
maximum_clients_per_user = 999999999
[quic]
initial_mtu = __MTU__
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
  sed -i "s|__PORT__|$TUIC_PORT|g" "$TUIC_TOML"
  sed -i "s|__UUID__|$TUIC_UUID|g" "$TUIC_TOML"
  sed -i "s|__PASS__|$TUIC_PASS|g" "$TUIC_TOML"
  sed -i "s|__SECRET__|$(openssl rand -hex 16)|g" "$TUIC_TOML"
  sed -i "s|__MTU__|$((1200 + RANDOM % 200))|g" "$TUIC_TOML"
}

# ========== 生成 VLESS 配置 ==========
gen_vless_config() {
  shortId=$(openssl rand -hex 8)
  keys=$("$VLESS_BIN" x25519 2>/dev/null || echo "Private key: a\nPublic key: b")
  priv=$(echo "$keys" | awk '/Private/ {print $3}')
  pub=$(echo "$keys" | awk '/Public/ {print $3}')

cat > "$VLESS_CONFIG" <<'EOF'
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": __PORT__,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "__UUID__", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "__DOMAIN__:443",
        "xver": 0,
        "serverNames": ["__DOMAIN__", "www.microsoft.com"],
        "privateKey": "__PRIV__",
        "publicKey": "__PUB__",
        "shortIds": ["__SID__"],
        "fingerprint": "chrome",
        "spiderX": "/"
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
  sed -i "s|__PORT__|$VLESS_PORT|g" "$VLESS_CONFIG"
  sed -i "s|__UUID__|$VLESS_UUID|g" "$VLESS_CONFIG"
  sed -i "s|__DOMAIN__|$MASQ_DOMAIN|g" "$VLESS_CONFIG"
  sed -i "s|__PRIV__|$priv|g" "$VLESS_CONFIG"
  sed -i "s|__PUB__|$pub|g" "$VLESS_CONFIG"
  sed -i "s|__SID__|$shortId|g" "$VLESS_CONFIG"

  echo "Reality Public Key: $pub" > reality_info.txt
  echo "Reality Short ID: $shortId" >> reality_info.txt
  echo "VLESS UUID: $VLESS_UUID" >> reality_info.txt
  echo "VLESS Port: $VLESS_PORT" >> reality_info.txt
}

# ========== 生成链接 ==========
gen_links() {
  ip="$1"
  pub=$(grep "Public Key" reality_info.txt | awk '{print $4}')
  sid=$(grep "Short ID" reality_info.txt | awk '{print $4}')

  printf "tuic://%s:%s@%s:%s?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=%s&udp_relay_mode=native#TUIC\n" \
    "$TUIC_UUID" "$TUIC_PASS" "$ip" "$TUIC_PORT" "$MASQ_DOMAIN" > "$TUIC_LINK"

  printf "vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&spx=/#VLESS-Reality-80\n" \
    "$VLESS_UUID" "$ip" "$VLESS_PORT" "$MASQ_DOMAIN" "$pub" "$sid" > "$VLESS_LINK"

  echo "TUIC Link:"
  cat "$TUIC_LINK"
  echo "VLESS Link:"
  cat "$VLESS_LINK"
}

# ========== 启动 ==========
run_tuic() { while :; do "$TUIC_BIN" -c "$TUIC_TOML" >/dev/null 2>&1 || sleep 5; done & }
run_vless() { while :; do "$VLESS_BIN" run -c "$VLESS_CONFIG" >/dev/null 2>&1 || sleep 5; done & }

# ========== 主函数 ==========
main() {
  load_config
  [[ -z "${TUIC_UUID:-}" ]] && TUIC_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)
  [[ -z "${TUIC_PASS:-}" ]] && TUIC_PASS=$(openssl rand -hex 16)
  [[ -z "${VLESS_UUID:-}" ]] && VLESS_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)

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

main "$@"
