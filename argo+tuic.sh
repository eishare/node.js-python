#!/bin/bash
# =========================================
# TUIC v5 over QUIC 自动部署脚本（纯 Shell 版，无需 root）
# 修复 Pterodactyl 下端口识别、TUIC 链接中文问题及 $1 unbound variable
# =========================================
set -euo pipefail
IFS=$'\n\t'

# -------------------- 配置 --------------------
MASQ_DOMAINS=("www.bing.com" "www.cloudflare.com" "cdn.jsdelivr.net" "www.google.com" "www.microsoft.com")
SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
LINK_TXT="tuic_link.txt"
TUIC_BIN="./tuic-server"

# -------------------- 工具函数 --------------------
random_port() { echo $(( (RANDOM % 40000) + 20000 )); }
random_sni() { echo "${MASQ_DOMAINS[$RANDOM % ${#MASQ_DOMAINS[@]}]}"; }
random_hex() { head -c "${1:-16}" /dev/urandom | xxd -p -c 256; }
uuid() { command -v uuidgen >/dev/null 2>&1 && uuidgen || cat /proc/sys/kernel/random/uuid; }
file_exists() { [[ -f "$1" ]]; }

download_file() {
  local url="$1" dest="$2"
  curl -L -o "$dest" "$url" --silent --show-error
}

# -------------------- 端口 --------------------
read_port() {
  local arg="$1"
  local port=""
  if [[ -n "$arg" && "$arg" =~ ^[0-9]+$ ]]; then
    port="$arg"
    echo "✅ 使用环境变量端口: $port" >&2
    echo "$port"
    return
  fi
  port=$(random_port)
  echo "🎲 自动分配随机端口: $port" >&2
  echo "$port"
}

# -------------------- 证书 --------------------
generate_cert() {
  local domain="$1"
  if file_exists "$CERT_PEM" && file_exists "$KEY_PEM"; then
    echo "🔐 证书已存在，跳过生成" >&2
    return
  fi
  echo "🔐 生成伪装证书 (${domain})..." >&2
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${domain}" -days 365 -nodes >/dev/null 2>&1
  chmod 600 "$KEY_PEM"
  chmod 644 "$CERT_PEM"
}

# -------------------- tuic-server --------------------
check_tuic_server() {
  if [[ -x "$TUIC_BIN" ]]; then
    echo "✅ tuic-server 已存在" >&2
    return
  fi
  echo "📥 下载 tuic-server v1.3.5..." >&2
  download_file "https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-x86_64-linux" "$TUIC_BIN"
  chmod +x "$TUIC_BIN"
  echo "✅ tuic-server 下载完成" >&2
}

# -------------------- 配置文件 --------------------
generate_config() {
  local uuid="$1"
  local password="$2"
  local port="$3"
  local domain="$4"
  local secret=$(random_hex 16)
  local mtu=$((1200 + RANDOM % 200))
cat > "$SERVER_TOML" <<EOF
log_level = "warn"
server = "0.0.0.0:${port}"

udp_relay_ipv6 = false
zero_rtt_handshake = true
dual_stack = false
auth_timeout = "8s"
task_negotiation_timeout = "4s"
gc_interval = "8s"
gc_lifetime = "8s"
max_external_packet_size = 8192

[users]
${uuid} = "${password}"

[tls]
certificate = "${CERT_PEM}"
private_key = "${KEY_PEM}"
alpn = ["h3"]

[restful]
addr = "127.0.0.1:${port}"
secret = "${secret}"
maximum_clients_per_user = 999999999

[quic]
initial_mtu = ${mtu}
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
  echo "⚙️ 配置文件已生成: $SERVER_TOML" >&2
}

# -------------------- 公网IP --------------------
get_public_ip() {
  curl -s --connect-timeout 3 https://api64.ipify.org || echo "127.0.0.1"
}

# -------------------- TUIC 链接 --------------------
generate_link() {
  local uuid="$1"
  local password="$2"
  local ip="$3"
  local port="$4"
  local domain="$5"
  local link="tuic://${uuid}:${password}@${ip}:${port}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${domain}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${ip}"
  echo "$link" > "$LINK_TXT"
  echo "🔗 TUIC 链接已生成:"
  cat "$LINK_TXT"
}

# -------------------- 守护 --------------------
run_loop() {
  echo "🚀 启动 TUIC 服务 (端口: ${TUIC_PORT})..." >&2
  while true; do
    "$TUIC_BIN" -c "$SERVER_TOML" >/dev/null 2>&1 || true
    echo "⚠️ TUIC 异常退出，5 秒后重启..." >&2
    sleep 5
  done
}

# -------------------- 主流程 --------------------
main() {
  echo "🌐 TUIC v5 over QUIC 自动部署开始" >&2

  # ✅ 彻底解决 $1 unbound variable，直接从 SERVER_PORT 或随机端口
  TUIC_PORT=$(read_port "${SERVER_PORT:-}")
  DOMAIN=$(random_sni)
  UUID=$(uuid)
  PASSWORD=$(random_hex 16)

  generate_cert "$DOMAIN"
  check_tuic_server
  generate_config "$UUID" "$PASSWORD" "$TUIC_PORT" "$DOMAIN"
  IP=$(get_public_ip)
  generate_link "$UUID" "$PASSWORD" "$IP" "$TUIC_PORT" "$DOMAIN"
  run_loop
}

main
