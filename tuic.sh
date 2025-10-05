#!/bin/bash
# TUIC v5 over QUIC 自动部署脚本（支持 Pterodactyl SERVER_PORT 和命令行参数）
set -euo pipefail
IFS=$'\n\t'

MASQ_DOMAINS=(
  "www.microsoft.com"
  "www.cloudflare.com"
  "www.bing.com"
  "www.apple.com"
  "www.amazon.com"
  "www.wikipedia.org"
  "cdnjs.cloudflare.com"
  "cdn.jsdelivr.net"
  "static.cloudflareinsights.com"
  "www.speedtest.net"
)
MASQ_DOMAIN=${MASQ_DOMAINS[$RANDOM % ${#MASQ_DOMAINS[@]}]}

SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
LINK_TXT="tuic_link.txt"
TUIC_BIN="./tuic-server"

# ===================== 输入端口或读取环境变量 =====================
read_port() {
  # 优先捕获命令行参数 $1
  if [[ -n "$1" ]]; then
    local port_arg="$1"
    if [[ "$port_arg" =~ ^[0-9]+$ && "$port_arg" -ge 1024 && "$port_arg" -le 65535 ]]; then
      TUIC_PORT="$port_arg"
      echo "✅ 从命令行参数读取 TUIC(QUIC) 端口: $TUIC_PORT"
      return
    else
      echo "❌ 命令行参数端口无效 ($port_arg)。"
    fi
  fi
    
  # 检查环境变量（适用于 Pterodactyl 等面板）
  if [[ -n "${SERVER_PORT:-}" ]]; then
    # 注意：使用 $SERVER_PORT 环境变量，而不是 $2
    TUIC_PORT="${SERVER_PORT}"
    echo "✅ 从环境变量读取 TUIC(QUIC) 端口: $TUIC_PORT"
    return
  fi

  local port
  while true; do
    echo "⚙️ 请输入 TUIC(QUIC) 端口 (1024-65535):"
    read -rp "> " port
    if [[ ! "$port" =~ ^[0-9]+$ || "$port" -lt 1024 || "$port" -gt 65535 ]]; then
      echo "❌ 无效端口: $port"
      continue
    fi
    TUIC_PORT="$port"
    break
  done
}

# ===================== 加载已有配置 =====================
load_existing_config() {
  if [[ -f "$SERVER_TOML" ]]; then
    TUIC_PORT=$(grep '^server = ' "$SERVER_TOML" | sed -E 's/.*:(.*)\"/\1/')
    TUIC_UUID=$(grep '^\[users\]' -A1 "$SERVER_TOML" | tail -n1 | awk '{print $1}')
    TUIC_PASSWORD=$(grep '^\[users\]' -A1 "$SERVER_TOML" | tail -n1 | awk -F'"' '{print $2}')
    echo "📂 检测到已有配置，加载中..."
    echo "✅ 端口: $TUIC_PORT"
    echo "✅ UUID: $TUIC_UUID"
    echo "✅ 密码: $TUIC_PASSWORD"
    return 0
  fi
  return 1
}

# ===================== 证书生成 =====================
generate_cert() {
  if [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]]; then
    echo "🔐 检测到已有证书，跳过生成"
    return
  fi
  echo "🔐 生成自签 ECDSA-P256 证书..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
  chmod 600 "$KEY_PEM"
  chmod 644 "$CERT_PEM"
  echo "✅ 自签证书生成完成"
}

# ===================== 检查并下载 tuic-server =====================
check_tuic_server() {
  if [[ -x "$TUIC_BIN" ]]; then
    echo "✅ 已找到 tuic-server"
    return
  fi
  echo "📥 未找到 tuic-server，正在下载..."
  ARCH=$(uname -m)
  if [[ "$ARCH" != "x86_64" ]]; then
    echo "❌ 暂不支持架构: $ARCH"
    exit 1
  fi
  TUIC_URL="https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-x86_64-linux"
  if curl -L -f -o "$TUIC_BIN" "$TUIC_URL"; then
    chmod +x "$TUIC_BIN"
    echo "✅ tuic-server 下载完成"
  else
    echo "❌ 下载失败，请手动下载 $TUIC_URL"
    exit 1
  fi
}

# ===================== 生成配置文件 =====================
generate_config() {
  cat > "$SERVER_TOML" <<EOF
log_level = "off"
server = "0.0.0.0:${TUIC_PORT}"

udp_relay_ipv6 = false
zero_rtt_handshake = true
dual_stack = false
auth_timeout = "10s"
task_negotiation_timeout = "5s"
gc_interval = "10s"
gc_lifetime = "10s"
max_external_packet_size = 8192

[users]
${TUIC_UUID} = "${TUIC_PASSWORD}"

[tls]
self_sign = false
certificate = "$CERT_PEM"
private_key = "$KEY_PEM"
alpn = ["h3"]

[restful]
addr = "127.0.0.1:${TUIC_PORT}"
secret = "$(openssl rand -hex 16)"
maximum_clients_per_user = 999999999

[quic]
initial_mtu = 1500
min_mtu = 1200
gso = true
pmtu = true
send_window = 33554432
receive_window = 16777216
max_idle_time = "20s"

[quic.congestion_control]
controller = "bbr"
initial_window = 4194304
EOF
}

# ===================== 获取公网 IP =====================
get_server_ip() {
  ip=$(curl -s --connect-timeout 3 https://api.ipify.org || true)
  echo "${ip:-YOUR_SERVER_IP}"
}

# ===================== 生成 TUIC 链接 =====================
generate_link() {
  local ip="$1"
  cat > "$LINK_TXT" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-HIGH-PERF-${ip}
EOF

  echo ""
  echo "📱 TUIC 链接已生成并保存到 $LINK_TXT"
  echo "🔗 订阅链接："
  cat "$LINK_TXT"
  echo ""
}

# ===================== 后台循环守护 =====================
run_background_loop() {
  echo "✅ 服务已启动，tuic-server 正在运行..."
  while true; do
    "$TUIC_BIN" -c "$SERVER_TOML"
    sleep 5
  done
}

# ===================== 主逻辑 =====================
main() {
  # 注意："$@" 包含了传递给脚本的所有参数，如端口号
  if ! load_existing_config; then
    echo "⚙️ 第一次运行，开始初始化..."
    # 将所有参数（如果存在）传递给 read_port
    read_port "$@" 
    TUIC_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null)"
    TUIC_PASSWORD="$(openssl rand -hex 16)"
    echo "🔑 UUID: $TUIC_UUID"
    echo "🔑 密码: $TUIC_PASSWORD"
    echo "🎯 SNI: $MASQ_DOMAIN"
    generate_cert
    check_tuic_server
    generate_config
  else
    generate_cert
    check_tuic_server
  fi

  ip="$(get_server_ip)"
  generate_link "$ip"
  run_background_loop
}

main "$@"
