#!/bin/bash
# TUIC v5 over QUIC 自动部署（Alpine 适配，openssl 可选）
set -euo pipefail
IFS=$'\n\t'

MASQ_DOMAIN="www.bing.com"
SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
LINK_TXT="tuic_link.txt"
TUIC_BIN="./tuic-server"

# ---------- 输入端口 ----------
read_port() {
  if [[ $# -ge 1 && -n "${1:-}" ]]; then
    TUIC_PORT="$1"; echo "✅ 从命令行读取 TUIC 端口: $TUIC_PORT"; return
  fi
  if [[ -n "${SERVER_PORT:-}" ]]; then
    TUIC_PORT="$SERVER_PORT"; echo "✅ 从环境变量读取 TUIC 端口: $TUIC_PORT"; return
  fi
  while true; do
    read -rp "⚙️ 请输入 TUIC 端口 (1024-65535): " port
    [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1024 && "$port" -le 65535 ]] && TUIC_PORT="$port" && break
  done
}

# ---------- 加载已有配置 ----------
load_config() {
  [[ -f "$SERVER_TOML" ]] || return 1
  TUIC_PORT=$(grep '^server =' "$SERVER_TOML" | sed -E 's/.*:(.*)\"/\1/')
  TUIC_UUID=$(grep '^\[users\]' -A1 "$SERVER_TOML" | tail -n1 | awk '{print $1}')
  TUIC_PASSWORD=$(grep '^\[users\]' -A1 "$SERVER_TOML" | tail -n1 | awk -F'"' '{print $2}')
  echo "📂 已加载配置: $TUIC_PORT / $TUIC_UUID / $TUIC_PASSWORD"
}

# ---------- 生成自签证书 ----------
generate_cert() {
  [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]] && { echo "🔐 已有证书，跳过生成"; return; }
  echo "🔐 生成自签证书..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
  chmod 600 "$KEY_PEM"; chmod 644 "$CERT_PEM"
  echo "✅ 自签证书生成完成"
}

# ---------- 下载 tuic-server (musl 版本) ----------
check_tuic() {
  [[ -x "$TUIC_BIN" ]] && { echo "✅ 已存在 tuic-server"; return; }
  echo "📥 下载 tuic-server (musl)..."
  TUIC_URL="https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-x86_64-musl"
  curl -L -o "$TUIC_BIN" "$TUIC_URL"
  chmod +x "$TUIC_BIN"
  echo "✅ tuic-server 下载完成"
}

# ---------- 生成配置 ----------
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
secret = "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
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

# ---------- 获取公网 IP ----------
get_ip() {
  curl -s --connect-timeout 3 https://api.ipify.org || echo "YOUR_SERVER_IP"
}

# ---------- 生成 TUIC 链接 ----------
generate_link() {
  cat > "$LINK_TXT" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${1}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${1}
EOF
  echo "📱 TUIC 链接已生成: $LINK_TXT"
}

# ---------- 卸载 TUIC ----------
uninstall_tuic() {
  echo "⚠️ 卸载 TUIC..."
  pkill -f "$TUIC_BIN" || true
  rm -f "$TUIC_BIN" "$SERVER_TOML" "$CERT_PEM" "$KEY_PEM" "$LINK_TXT"
  echo "✅ TUIC 已卸载"
}

# ---------- 后台循环 ----------
run_loop() {
  echo "✅ 服务启动，tuic-server 正在运行..."
  while true; do "$TUIC_BIN" -c "$SERVER_TOML"; echo "⚠️ tuic-server 已退出，5秒后重启..."; sleep 5; done
}

# ---------- 主函数 ----------
main() {
  if [[ "${1:-}" == "uninstall" ]]; then uninstall_tuic; exit 0; fi

  if ! load_config; then
    echo "⚙️ 第一次运行，初始化中..."
    read_port "$@"
    TUIC_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null)"
    TUIC_PASSWORD=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    echo "🔑 UUID: $TUIC_UUID"; echo "🔑 密码: $TUIC_PASSWORD"; echo "🎯 SNI: ${MASQ_DOMAIN}"
    generate_cert
    check_tuic
    generate_config
  else
    generate_cert
    check_tuic
  fi

  IP=$(get_ip)
  generate_link "$IP"
  run_loop
}

main "$@"



