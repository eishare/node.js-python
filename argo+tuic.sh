#!/bin/bash
# =========================================
# TUIC v5 一键部署（Pterodactyl 自适应端口版）
# =========================================
set -euo pipefail
IFS=$'\n\t'

MASQ_DOMAIN="www.cloudflare.com"
SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
LINK_TXT="tuic_link.txt"
TUIC_BIN="./tuic-server"

# 随机函数
random_port() { echo $(( (RANDOM % 40000) + 20000 )); }
random_sni() {
  local list=( "www.cloudflare.com" "www.bing.com" "cdn.jsdelivr.net" "www.google.com" "www.microsoft.com" )
  echo "${list[$RANDOM % ${#list[@]}]}"
}

# ✅ 自动检测可用端口（Pterodactyl 兼容）
detect_real_port() {
  # 1️⃣ 优先取环境变量
  if [[ -n "${SERVER_PORT:-}" ]]; then
    echo "🔧 检测到 SERVER_PORT 环境变量: $SERVER_PORT"
    echo "$SERVER_PORT"
    return
  fi
  if [[ -n "${PORT:-}" ]]; then
    echo "🔧 检测到 PORT 环境变量: $PORT"
    echo "$PORT"
    return
  fi

  # 2️⃣ 检查面板常见路径
  if [[ -f "/home/container/ports.txt" ]]; then
    PORTTXT=$(head -n1 /home/container/ports.txt | grep -oE '[0-9]+')
    if [[ -n "$PORTTXT" ]]; then
      echo "🔧 从 /home/container/ports.txt 检测到端口: $PORTTXT"
      echo "$PORTTXT"
      return
    fi
  fi

  # 3️⃣ 扫描容器已开放端口
  PORTSCAN=$(ss -tuln | awk '/LISTEN/ && !/127.0.0.1/ {print $5}' | grep -oE '[0-9]+$' | head -n1 || true)
  if [[ -n "$PORTSCAN" ]]; then
    echo "🔧 自动检测到开放端口: $PORTSCAN"
    echo "$PORTSCAN"
    return
  fi

  # 4️⃣ 最后兜底随机
  echo "⚠️ 未检测到开放端口，使用随机端口"
  random_port
}

# 生成证书
generate_cert() {
  if [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]]; then
    echo "🔐 证书存在，跳过"
    return
  fi
  MASQ_DOMAIN=$(random_sni)
  echo "🔐 生成伪装证书 (${MASQ_DOMAIN})..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
}

# 下载 tuic-server
check_tuic_server() {
  if [[ -x "$TUIC_BIN" ]]; then
    echo "✅ tuic-server 已存在"
    return
  fi
  echo "📥 下载 tuic-server..."
  curl -L -o "$TUIC_BIN" "https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-x86_64-linux"
  chmod +x "$TUIC_BIN"
}

# 生成配置
generate_config() {
cat > "$SERVER_TOML" <<EOF
log_level = "warn"
server = "0.0.0.0:${TUIC_PORT}"
udp_relay_ipv6 = false
zero_rtt_handshake = true

[users]
${TUIC_UUID} = "${TUIC_PASSWORD}"

[tls]
certificate = "$CERT_PEM"
private_key = "$KEY_PEM"
alpn = ["h3"]

[quic]
send_window = 33554432
receive_window = 16777216
max_idle_time = "25s"
[quic.congestion_control]
controller = "bbr"
EOF
}

# 获取公网IP
get_server_ip() {
  curl -s --connect-timeout 3 https://api64.ipify.org || echo "127.0.0.1"
}

# 生成 TUIC 链接
generate_link() {
  local ip="$1"
  cat > "$LINK_TXT" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1#TUIC-${ip}
EOF
  echo "🔗 TUIC 链接已生成: $(cat "$LINK_TXT")"
}

# 守护进程
run_background_loop() {
  echo "🚀 启动 TUIC 服务 (端口: ${TUIC_PORT})..."
  while true; do
    "$TUIC_BIN" -c "$SERVER_TOML" >/dev/null 2>&1 || true
    echo "⚠️ TUIC 异常退出，5秒后重启..."
    sleep 5
  done
}

# 主流程
main() {
  TUIC_PORT=$(detect_real_port)
  echo "✅ 最终使用端口: ${TUIC_PORT}"

  TUIC_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
  TUIC_PASSWORD="$(openssl rand -hex 16)"
  generate_cert
  check_tuic_server
  generate_config

  ip="$(get_server_ip)"
  generate_link "$ip"
  run_background_loop
}

main "$@"
