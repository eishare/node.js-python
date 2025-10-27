#!/bin/bash
# =========================================
# TUIC v5 over QUIC 自动部署脚本（纯 Shell 版，无需 root）
# 特性：
#  - 支持自定义端口参数或环境变量 SERVER_PORT
#  - 下载固定版本 v1.3.5 x86_64-linux tuic-server
#  - 随机伪装域名
#  - 自动生成证书
#  - 自动生成配置文件和 TUIC 链接
#  - 守护运行
# =========================================
set -euo pipefail
IFS=$'\n\t'

# -------------------- 配置 --------------------
MASQ_DOMAINS=("www.bing.com")
SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
LINK_TXT="tuic_link.txt"
TUIC_BIN="./tuic-server"

# -------------------- 工具函数 --------------------
random_port() { echo $(( (RANDOM % 40000) + 20000 )); }
random_sni() { echo "${MASQ_DOMAINS[$RANDOM % ${#MASQ_DOMAINS[@]}]}"; }
random_hex() { head -c "${1:-16}" /dev/urandom | xxd -p -c 256; }
uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  else
    cat /proc/sys/kernel/random/uuid
  fi
}
file_exists() { [[ -f "$1" ]]; }

exec_safe() { 
  "$@" >/dev/null 2>&1 || true
}

download_file() {
  local url="$1" dest="$2" redirects="${3:-0}"
  if (( redirects > 5 )); then
    echo "❌ 重定向次数过多"; return 1
  fi
  if command -v curl >/dev/null 2>&1; then
    http_code=$(curl -L -w "%{http_code}" -o "$dest" "$url" --silent --show-error)
    if [[ "$http_code" == "200" ]]; then return 0; fi
    if [[ "$http_code" =~ ^30[1237]$ ]]; then
      local newurl=$(curl -sI "$url" | grep -i Location | awk '{print $2}' | tr -d '\r')
      rm -f "$dest"
      download_file "$newurl" "$dest" $((redirects + 1))
    else
      echo "❌ 下载失败: $http_code"; return 1
    fi
  else
    echo "❌ 未安装 curl"; return 1
  fi
}

# -------------------- 端口 --------------------
read_port() {
  if [[ -n "${1:-}" && "$1" =~ ^[0-9]+$ ]]; then
    echo "$1"
    return
  fi
  if [[ -n "${SERVER_PORT:-}" && "$SERVER_PORT" =~ ^[0-9]+$ ]]; then
    echo "$SERVER_PORT"
    return
  fi
  echo "$(random_port)"
}

# -------------------- 证书 --------------------
generate_cert() {
  local domain="$1"
  if file_exists "$CERT_PEM" && file_exists "$KEY_PEM"; then
    echo "🔐 证书已存在，跳过"
    return
  fi
  echo "🔐 生成伪装证书 (${domain})..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${domain}" -days 365 -nodes >/dev/null 2>&1
  chmod 600 "$KEY_PEM"
  chmod 644 "$CERT_PEM"
}

# -------------------- tuic-server --------------------
check_tuic_server() {
  if [[ -x "$TUIC_BIN" ]]; then
    echo "✅ tuic-server 已存在"
    return
  fi
  echo "📥 下载 tuic-server v1.3.5..."
  download_file "https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-x86_64-linux" "$TUIC_BIN"
  chmod +x "$TUIC_BIN"
  echo "✅ tuic-server 下载完成"
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
  echo "⚙️ 配置文件已生成: $SERVER_TOML"
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
  echo "$link"
}

# -------------------- 守护 --------------------
run_loop() {
  echo "🚀 启动 TUIC 服务..."
  while true; do
    "$TUIC_BIN" -c "$SERVER_TOML" >/dev/null 2>&1 || true
    echo "⚠️ TUIC 异常退出，5 秒后重启..."
    sleep 5
  done
}

# -------------------- 主流程 --------------------
main() {
  echo "🌐 TUIC v5 over QUIC 自动部署开始"

  PORT=$(read_port "$1")
  DOMAIN=$(random_sni)
  UUID=$(uuid)
  PASSWORD=$(random_hex 16)

  generate_cert "$DOMAIN"
  check_tuic_server
  generate_config "$UUID" "$PASSWORD" "$PORT" "$DOMAIN"
  IP=$(get_public_ip)
  generate_link "$UUID" "$PASSWORD" "$IP" "$PORT" "$DOMAIN"
  run_loop
}

main "$@"
