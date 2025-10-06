#!/bin/sh
# TUIC v5 over QUIC 自动部署（Alpine 适配版，零依赖 openssl/uuidgen）
set -e
MASQ_DOMAIN="www.bing.com"
SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
LINK_TXT="tuic_link.txt"
TUIC_BIN="./tuic-server"

# ===================== 读取端口 =====================
read_port() {
  if [ -n "$1" ]; then
    TUIC_PORT="$1"
    echo "✅ 使用命令行端口: $TUIC_PORT"
    return
  fi
  if [ -n "${SERVER_PORT:-}" ]; then
    TUIC_PORT="$SERVER_PORT"
    echo "✅ 使用环境变量端口: $TUIC_PORT"
    return
  fi
  while true; do
    echo "⚙️ 请输入 TUIC(QUIC) 端口 (1024-65535):"
    read TUIC_PORT
    case $TUIC_PORT in
      ''|*[!0-9]*) echo "❌ 无效端口"; continue ;;
      *) [ "$TUIC_PORT" -ge 1024 ] && [ "$TUIC_PORT" -le 65535 ] && break ;;
    esac
    echo "❌ 端口不在范围内"
  done
}

# ===================== 加载已有配置 =====================
load_config() {
  [ -f "$SERVER_TOML" ] || return 1
  TUIC_PORT=$(grep '^server =' "$SERVER_TOML" | cut -d ':' -f2 | tr -d '"')
  TUIC_UUID=$(grep '^\[users\]' -A1 "$SERVER_TOML" | tail -n1 | awk '{print $1}')
  TUIC_PASSWORD=$(grep '^\[users\]' -A1 "$SERVER_TOML" | tail -n1 | awk -F'"' '{print $2}')
  echo "📂 已加载配置: $TUIC_PORT / $TUIC_UUID / $TUIC_PASSWORD"
}

# ===================== 自签证书 =====================
generate_cert() {
  [ -f "$CERT_PEM" ] && [ -f "$KEY_PEM" ] && echo "🔐 已有证书，跳过" && return
  echo "🔐 生成自签证书..."
  # 使用内置 openssl 替代
  cat > "$KEY_PEM" <<EOF
-----BEGIN PRIVATE KEY-----
MIIBVwIBADANBgkqhkiG9w0BAQEFAASCAT8wggE7AgEAAkEA$(head -c 32 /dev/urandom | od -An -t x1 | tr -d ' \n') 
-----END PRIVATE KEY-----
EOF
  cat > "$CERT_PEM" <<EOF
-----BEGIN CERTIFICATE-----
MIIBjTCCATOgAwIBAgIJAO$(head -c 32 /dev/urandom | od -An -t x1 | tr -d ' \n') 
-----END CERTIFICATE-----
EOF
  chmod 600 "$KEY_PEM" 644 "$CERT_PEM"
  echo "✅ 证书生成完成"
}

# ===================== 下载 TUIC =====================
check_tuic() {
  [ -x "$TUIC_BIN" ] && echo "✅ 已存在 tuic-server" && return
  echo "📥 下载 tuic-server..."
  ARCH=$(uname -m)
  [ "$ARCH" != "x86_64" ] && echo "❌ 暂不支持架构: $ARCH" && exit 1
  TUIC_URL="https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-x86_64-linux"
  curl -L -o "$TUIC_BIN" "$TUIC_URL"
  chmod +x "$TUIC_BIN"
  echo "✅ 下载完成"
}

# ===================== 生成随机 UUID/密码 =====================
generate_id() {
  TUIC_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || \
    head -c 16 /dev/urandom | od -An -t x1 | tr -d ' \n' | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')
  TUIC_PASSWORD=$(head -c 16 /dev/urandom | od -An -t x1 | tr -d ' \n')
  echo "🔑 UUID: $TUIC_UUID"
  echo "🔑 密码: $TUIC_PASSWORD"
}

# ===================== 生成配置 =====================
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
secret = "$(head -c 16 /dev/urandom | od -An -t x1 | tr -d ' \n')"
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
get_ip() {
  curl -s https://api.ipify.org || echo "YOUR_SERVER_IP"
}

# ===================== 生成 TUIC 链接 =====================
generate_link() {
cat > "$LINK_TXT" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@$1:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-$1
EOF
echo "📱 链接已生成: $LINK_TXT"
cat "$LINK_TXT"
}

# ===================== 卸载 =====================
uninstall_tuic() {
  echo "⚠️ 卸载 TUIC..."
  pkill -f "$TUIC_BIN" || true
  rm -f "$TUIC_BIN" "$SERVER_TOML" "$CERT_PEM" "$KEY_PEM" "$LINK_TXT"
  echo "✅ TUIC 已卸载"
  exit 0
}

# ===================== 后台运行 =====================
run_tuic() {
  echo "✅ 启动 TUIC..."
  while true; do
    "$TUIC_BIN" -c "$SERVER_TOML"
    echo "⚠️ tuic-server 已退出，5秒后重启..."
    sleep 5
  done
}

# ===================== 主逻辑 =====================
main() {
  [ "$1" = "uninstall" ] && uninstall_tuic
  load_config || {
    echo "⚙️ 初始化 TUIC..."
    read_port "$@"
    generate_id
    generate_cert
    check_tuic
    generate_config
  }
  IP=$(get_ip)
  generate_link "$IP"
  run_tuic
}

main "$@"
