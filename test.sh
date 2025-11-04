#!/bin/bash
# =========================================
# TUIC (动态端口) + VLESS-WS-TLS (443) 一键部署
# 翼龙面板专用：TUIC 用面板端口，VLESS 用服务器 443
# 自动 setcap 权限，免 root 绑定 443
# =========================================
set -euo pipefail
export LC_ALL=C
IFS=$'\n\t'

# ========== 自动检测 TUIC 端口（翼龙面板开放的端口）==========
detect_tuic_port() {
  # 优先：环境变量 SERVER_PORT
  if [[ -n "${SERVER_PORT:-}" ]]; then
    TUIC_PORT="$SERVER_PORT"
    echo "TUIC Port (env): $TUIC_PORT"
    return
  fi
  # 次选：命令行参数
  if [[ $# -ge 1 && -n "$1" ]]; then
    TUIC_PORT="$1"
    echo "TUIC Port (arg): $TUIC_PORT"
    return
  fi
  # 默认：3250
  TUIC_PORT=3250
  echo "TUIC Port (default): $TUIC_PORT"
}

# ========== 固定 VLESS-WS-TLS 端口：443 ==========
VLESS_PORT=443

# ========== 文件定义 ==========
MASQ_DOMAIN="www.bing.com"
TUIC_TOML="server.toml"
TUIC_BIN="./tuic-server"
TUIC_LINK="tuic_link.txt"

VLESS_BIN="./xray"
VLESS_CONFIG="vless-ws-tls.json"
VLESS_LINK="vless_link.txt"

CERT_PEM="fullchain.pem"
KEY_PEM="privkey.pem"

# ========== 加载配置 ==========
load_config() {
  if [[ -f "$TUIC_TOML" ]]; then
    TUIC_UUID=$(grep '^\[users\]' -A2 "$TUIC_TOML" | tail -n1 | awk '{print $1}')
    TUIC_PASS=$(grep '^\[users\]' -A2 "$TUIC_TOML" | tail -n1 | awk -F'"' '{print $3}')
  fi
  if [[ -f "$VLESS_CONFIG" ]]; then
    VLESS_UUID=$(grep -o '"id": "[^"]*' "$VLESS_CONFIG" | head -1 | cut -d'"' -f4)
    WS_PATH=$(grep -o '/[a-f0-9]\{16\}' "$VLESS_CONFIG" | head -1 || echo "")
  fi
}

# ========== 生成自签名证书（VLESS TLS 用）==========
gen_cert() {
  [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]] && return
  echo "Generating TLS cert for $MASQ_DOMAIN..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=$MASQ_DOMAIN" -days 365 -nodes >/dev/null 2>&1
  chmod 644 "$CERT_PEM" 2>/dev/null || true
  chmod 600 "$KEY_PEM" 2>/dev/null || true
}

# ========== 下载 tuic-server ==========
get_tuic() {
  [[ -x "$TUIC_BIN" ]] && return
  echo "Downloading tuic-server..."
  curl -L -o "$TUIC_BIN" "https://github.com/Itsusinn/tuic/releases/download/v1.4.5/tuic-server-x86_64-linux" --fail --connect-timeout 10
  chmod +x "$TUIC_BIN"
}

# ========== 下载 Xray ==========
get_xray() {
  [[ -x "$VLESS_BIN" ]] && return
  echo "Downloading Xray..."
  curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/download/v1.8.23/Xray-linux-64.zip" --fail --connect-timeout 15
  unzip -j xray.zip xray -d . >/dev/null 2>&1
  rm xray.zip
  chmod +x "$VLESS_BIN"
}

# ========== 自动赋予 443 端口绑定权限 ==========
grant_443_permission() {
  if [[ "$VLESS_PORT" -eq 443 ]]; then
    echo "Granting xray permission to bind port 443..."
    if command -v setcap >/dev/null 2>&1; then
      setcap cap_net_bind_service=+ep "$VLESS_BIN" 2>/dev/null || echo "setcap failed (ignore if container has CAP_NET_BIND_SERVICE)"
    else
      # 尝试安装 libcap
      (apt update && apt install -y libcap2-bin) >/dev/null 2>&1 || \
      (yum install -y libcap) >/dev/null 2>&1 || \
      echo "libcap not available. Ensure container has CAP_NET_BIND_SERVICE"
    fi
  fi
}

# ========== 生成 TUIC 配置 ==========
gen_tuic_config() {
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
${TUIC_UUID} = "${TUIC_PASS}"
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

# ========== 生成 VLESS-WS-TLS 配置（443 端口）==========
gen_vless_config() {
  [[ -z "${WS_PATH:-}" ]] && WS_PATH="/$(openssl rand -hex 8)"
cat > "$VLESS_CONFIG" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": $VLESS_PORT,
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
gen_links() {
  local ip="$1"
  cat > "$TUIC_LINK" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASS}@${ip}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native#TUIC-${TUIC_PORT}
EOF

  cat > "$VLESS_LINK" <<EOF
vless://${VLESS_UUID}@${ip}:${VLESS_PORT}?encryption=none&security=tls&type=ws&host=${MASQ_DOMAIN}&path=${WS_PATH}#VLESS-WS-TLS-443
EOF

  echo "========================================="
  echo "TUIC (Port: $TUIC_PORT):"
  cat "$TUIC_LINK"
  echo ""
  echo "VLESS-WS-TLS (Port: 443):"
  cat "$VLESS_LINK"
  echo "WS Path: $WS_PATH"
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
  echo "Starting VLESS-WS-TLS on :$VLESS_PORT (path: $WS_PATH)..."
  while true; do
    "$VLESS_BIN" run -c "$VLESS_CONFIG" >/dev/null 2>&1 || true
    echo "VLESS crashed. Restarting in 5s..."
    sleep 5
  done
}

# ========== 主函数 ==========
main() {
  echo "========================================="
  echo " TUIC (动态端口) + VLESS-WS-TLS (443)"
  echo " 翼龙面板专用部署脚本"
  echo "========================================="

  detect_tuic_port "$@"
  load_config

  # 生成 UUID 和密码
  [[ -z "${TUIC_UUID:-}" ]] && TUIC_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)
  [[ -z "${TUIC_PASS:-}" ]] && TUIC_PASS=$(openssl rand -hex 16)
  [[ -z "${VLESS_UUID:-}" ]] && VLESS_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)

  gen_cert
  get_tuic
  get_xray
  grant_443_permission
  gen_tuic_config
  gen_vless_config

  ip=$(curl -s https://api64.ipify.org || curl -s https://ifconfig.me || echo "127.0.0.1")
  gen_links "$ip"

  echo "Starting services..."
  run_tuic &
  run_vless &
  wait
}

main "$@"
