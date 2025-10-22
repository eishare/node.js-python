#!/bin/bash
# =========================================
# TUIC v5 over QUIC 手动端口部署脚本（免 root 版）
# 特性：抗 QoS 优化、随机握手、自动恢复、IPv4/IPv6 自适应
# 说明：需手动传入端口号，否则脚本会退出。
# 用法：bash <(curl -Ls https://yourdomain.com/tuic.sh) 12345
# =========================================
set -euo pipefail
IFS=$'\n\t'

MASQ_DOMAIN="www.bing.com"
SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
LINK_TXT="tuic_link.txt"
TUIC_BIN="./tuic-server"

# ===================== 随机 SNI =====================
random_sni() {
  local list=( "www.bing.com" "www.cloudflare.com" "www.microsoft.com" "www.google.com" "cdn.jsdelivr.net" )
  echo "${list[$RANDOM % ${#list[@]}]}"
}

# ===================== 检查端口参数 =====================
read_port() {
  if [[ $# -ge 1 && -n "${1:-}" ]]; then
    TUIC_PORT="30293"
    echo "✅ 使用指定端口: $TUIC_PORT"
  else
    echo "❌ 未指定端口。"
    echo "👉 用法示例: bash <(curl -Ls https://yourdomain.com/tuic.sh) 443"
    echo "（请手动指定宿主映射或 NAT 转发的端口号）"
    exit 1
  fi
}

# ===================== 加载已有配置 =====================
load_existing_config() {
  if [[ -f "$SERVER_TOML" ]]; then
    TUIC_PORT=$(grep '^server =' "$SERVER_TOML" | sed -E 's/.*:(.*)\"/\1/')
    TUIC_UUID=$(grep '^\[users\]' -A1 "$SERVER_TOML" | tail -n1 | awk '{print $1}')
    TUIC_PASSWORD=$(grep '^\[users\]' -A1 "$SERVER_TOML" | tail -n1 | awk -F'"' '{print $2}')
    echo "📂 已检测到配置文件，加载中..."
    return 0
  fi
  return 1
}

# ===================== 证书生成 =====================
generate_cert() {
  if [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]]; then
    echo "🔐 证书存在，跳过生成"
    return
  fi
  MASQ_DOMAIN=$(random_sni)
  echo "🔐 生成伪装证书 (${MASQ_DOMAIN})..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
  chmod 600 "$KEY_PEM"
  chmod 644 "$CERT_PEM"
}

# ===================== 下载 tuic-server =====================
check_tuic_server() {
  if [[ -x "$TUIC_BIN" ]]; then
    echo "✅ tuic-server 已存在"
    return
  fi
  echo "📥 下载 tuic-server 静态版..."
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) URL="https://github.com/EAimTY/tuic/releases/download/1.0.0/tuic-server-x86_64-unknown-linux-musl" ;;
    aarch64) URL="https://github.com/EAimTY/tuic/releases/download/1.0.0/tuic-server-aarch64-unknown-linux-musl" ;;
    *) echo "❌ 不支持的架构：$ARCH"; exit 1 ;;
  esac
  curl -L -o "$TUIC_BIN" "$URL" || { echo "❌ 下载失败"; exit 1; }
  chmod +x "$TUIC_BIN"
}

# ===================== 生成配置 =====================
generate_config() {
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

# ===================== 获取公网IP =====================
get_server_ip() {
  curl -s --connect-timeout 3 https://api64.ipify.org || echo "127.0.0.1"
}

# ===================== 生成TUIC链接 =====================
generate_link() {
  local ip="$1"
  cat > "$LINK_TXT" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${ip}
EOF
  echo "🔗 TUIC 链接已生成并保存到 ${LINK_TXT}"
  cat "$LINK_TXT"
}

# ===================== 循环守护 =====================
run_background_loop() {
  echo "🚀 启动 TUIC 服务 (监听端口 ${TUIC_PORT}) ..."
  while true; do
    "$TUIC_BIN" -c "$SERVER_TOML" >/dev/null 2>&1 || true
    echo "⚠️ TUIC 异常退出，5秒后重启..."
    sleep 5
  done
}

# ===================== 主流程 =====================
main() {
  if ! load_existing_config; then
    read_port "$@"
    TUIC_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
    TUIC_PASSWORD="$(openssl rand -hex 16)"
    generate_cert
    check_tuic_server
    generate_config
  else
    check_tuic_server
  fi

  ip="$(get_server_ip)"
  generate_link "$ip"
  run_background_loop
}

main "$@"
