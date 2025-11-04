#!/bin/bash
# =========================================
# TUIC + Hysteria2 双 UDP 共用端口
# 翼龙面板专用：自动检测端口
# 零冲突、超高速、双协议备份
# =========================================
set -uo pipefail

# ========== 自动检测端口（翼龙环境变量优先）==========
if [[ -n "${SERVER_PORT:-}" ]]; then
  PORT="$SERVER_PORT"
elif [[ $# -ge 1 && -n "$1" ]]; then
  PORT="$1"
else
  PORT=3250
fi
echo "Shared UDP Port: $PORT"

# ========== 文件定义 ==========
MASQ_DOMAIN="www.bing.com"
TUIC_TOML="tuic.toml"
TUIC_BIN="./tuic-server"
TUIC_LINK="tuic_link.txt"

HY2_BIN="./hysteria2"
HY2_CONFIG="hy2.yaml"
HY2_LINK="hy2_link.txt"

CERT_PEM="fullchain.pem"
KEY_PEM="privkey.pem"

# ========== 加载配置 ==========
load_config() {
  [[ -f "$TUIC_TOML" ]] && {
    TUIC_UUID=$(grep -A2 '^\[users\]' "$TUIC_TOML" | tail -n1 | awk '{print $1}')
    TUIC_PASS=$(grep -A2 '^\[users\]' "$TUIC_TOML" | tail -n1 | awk -F'"' '{print $3}')
  }
  [[ -f "$HY2_CONFIG" ]] && {
    HY2_PASS=$(grep '^password:' "$HY2_CONFIG" | awk '{print $2}')
  }
}

# ========== 生成自签名证书 ==========
gen_cert() {
  [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]] && return
  echo "Generating TLS cert..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=$MASQ_DOMAIN" -days 365 -nodes >/dev/null 2>&1
}

# ========== 下载 tuic-server ==========
get_tuic() {
  [[ -x "$TUIC_BIN" ]] && return
  echo "Downloading tuic-server..."
  curl -L -o "$TUIC_BIN" "https://github.com/Itsusinn/tuic/releases/download/v1.4.5/tuic-server-x86_64-linux" --fail --connect-timeout 10
  chmod +x "$TUIC_BIN"
}

# ========== 下载 Hysteria2 ==========
get_hy2() {
  [[ -x "$HY2_BIN" ]] && return
  echo "Downloading Hysteria2..."
  curl -L -o "$HY2_BIN" "https://github.com/apernet/hysteria/releases/download/app/v2.6.0/hysteria-linux-amd64" --fail --connect-timeout 10
  chmod +x "$HY2_BIN"
}

# ========== 生成 TUIC 配置 ==========
gen_tuic_config() {
  local secret=$(openssl rand -hex 16)
  local mtu=$((1200 + RANDOM % 200))
  cat > "$TUIC_TOML" <<EOF
log_level = "warn"
server = "[::]:$PORT"
udp_relay_ipv6 = true
zero_rtt_handshake = true
dual_stack = true
auth_timeout = "8s"
task_negotiation_timeout = "4s"
gc_interval = "8s"
gc_lifetime = "8s"
max_external_packet_size = 8192
[users]
$TUIC_UUID = "$TUIC_PASS"
[tls]
certificate = "$CERT_PEM"
private_key = "$KEY_PEM"
alpn = ["h3"]
[restful]
addr = "127.0.0.1:$PORT"
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

# ========== 生成 Hysteria2 配置 ==========
gen_hy2_config() {
  cat > "$HY2_CONFIG" <<EOF
listen: :$PORT

acme:
  domains:
    - $MASQ_DOMAIN
  email: admin@$MASQ_DOMAIN

auth:
  type: password
  password: $HY2_PASS

masquerade:
  type: proxy
  proxy:
    url: https://$MASQ_DOMAIN
    rewriteHost: true

transport:
  udp:
    hopInterval: 30s

bandwidth:
  up: 100 mbps
  down: 100 mbps

ignoreClientBandwidth: false

disableUDP: false

udpTimeout: 60s

tls:
  cert: $CERT_PEM
  key: $KEY_PEM
EOF
}

# ========== 生成客户端链接 ==========
gen_links() {
  local ip="$1"
  printf "tuic://%s:%s@%s:%s?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=%s&udp_relay_mode=native#TUIC\n" \
    "$TUIC_UUID" "$TUIC_PASS" "$ip" "$PORT" "$MASQ_DOMAIN" > "$TUIC_LINK"

  printf "hysteria2://%s@%s:%s/?sni=%s&alpn=h3&insecure=1#Hysteria2\n" \
    "$HY2_PASS" "$ip" "$PORT" "$MASQ_DOMAIN" > "$HY2_LINK"

  echo "========================================="
  echo "TUIC (QUIC/UDP):"
  cat "$TUIC_LINK"
  echo ""
  echo "Hysteria2 (UDP):"
  cat "$HY2_LINK"
  echo "========================================="
}

# ========== 启动服务 ==========
run_tuic() {
  echo "Starting TUIC on :$PORT (UDP)..."
  while :; do
    "$TUIC_BIN" -c "$TUIC_TOML" >/dev/null 2>&1 || sleep 5
  done &
}

run_hy2() {
  echo "Starting Hysteria2 on :$PORT (UDP)..."
  while :; do
    "$HY2_BIN" -c "$HY2_CONFIG" server >/dev/null 2>&1 || sleep 5
  done &
}

# ========== 主函数 ==========
main() {
  load_config

  # 生成密码
  [[ -z "${TUIC_UUID:-}" ]] && TUIC_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)
  [[ -z "${TUIC_PASS:-}" ]] && TUIC_PASS=$(openssl rand -hex 16)
  [[ -z "${HY2_PASS:-}" ]] && HY2_PASS=$(openssl rand -hex 16)

  gen_cert
  get_tuic
  get_hy2
  gen_tuic_config
  gen_hy2_config

  ip=$(curl -s https://api64.ipify.org || echo "127.0.0.1")
  gen_links "$ip"

  echo "Starting dual UDP services..."
  run_tuic
  run_hy2
  wait
}

main "$@"
