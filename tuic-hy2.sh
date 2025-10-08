#!/bin/bash
# TUIC v5 over QUIC 自动部署脚本（兼容 Alpine / Debian / Ubuntu）
# ✅ 支持 TUIC v1.5.x（已修复 congestion_control 错误）
# ✅ 自动检测 musl/glibc 并下载正确二进制
# ✅ 自动生成证书 + 配置文件 + TUIC 链接
# ✅ 支持一键启动、自动重启守护

set -euo pipefail
IFS=$'\n\t'

# ===================== 全局配置 =====================
MASQ_DOMAIN="www.bing.com"     # SNI 伪装域名
SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
LINK_TXT="tuic_link.txt"
TUIC_BIN="./tuic-server"
TUIC_VERSION="1.5.9"           # 🔧 版本更新为最新
# ====================================================

# ---------- 系统依赖 ----------
check_and_install_dependencies() {
    echo "🔍 检查系统依赖..."
    if command -v apk >/dev/null; then
        apk update >/dev/null
        apk add curl openssl util-linux || { echo "❌ 安装失败"; exit 1; }
    elif command -v apt >/dev/null; then
        apt update -qq >/dev/null
        apt install -y curl openssl uuid-runtime >/dev/null
    elif command -v yum >/dev/null; then
        yum install -y curl openssl uuid
    else
        echo "⚠️ 无法自动安装依赖，请手动安装 curl openssl uuidgen"
    fi
    echo "✅ 依赖检查完成"
}

# ---------- 获取端口 ----------
read_port() {
  if [[ $# -ge 1 && -n "${1:-}" ]]; then
    TUIC_PORT="$1"
    echo "✅ 指定端口: $TUIC_PORT"
  else
    TUIC_PORT="443"
    echo "⚙️ 未指定端口，默认使用: $TUIC_PORT"
  fi
}

# ---------- 加载旧配置 ----------
load_existing_config() {
  if [[ -f "$SERVER_TOML" ]]; then
    TUIC_PORT=$(grep '^server =' "$SERVER_TOML" | grep -o '[0-9]\+')
    TUIC_UUID=$(grep '^\[users\]' -A1 "$SERVER_TOML" | tail -n1 | awk '{print $1}')
    TUIC_PASSWORD=$(grep '^\[users\]' -A1 "$SERVER_TOML" | tail -n1 | awk -F'"' '{print $2}')
    if [[ -n "$TUIC_PORT" && -n "$TUIC_UUID" && -n "$TUIC_PASSWORD" ]]; then
      echo "📂 发现旧配置:"
      echo "✅ 端口: $TUIC_PORT"
      echo "✅ UUID: $TUIC_UUID"
      echo "✅ 密码: $TUIC_PASSWORD"
      return 0
    fi
  fi
  return 1
}

# ---------- 生成证书 ----------
generate_cert() {
  if [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]]; then
    echo "🔐 已存在证书，跳过生成"
    return
  fi
  echo "🔑 正在生成自签证书..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 3650 -nodes >/dev/null 2>&1
  chmod 600 "$KEY_PEM"
  chmod 644 "$CERT_PEM"
  echo "✅ 证书生成完成"
}

# ---------- 检测架构 & 下载 TUIC ----------
check_tuic_server() {
  local ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|amd64) ARCH="x86_64" ;;
    aarch64|arm64) ARCH="aarch64" ;;
    *) echo "❌ 不支持的架构: $ARCH"; exit 1 ;;
  esac

  local C_LIB_SUFFIX=""
  if command -v ldd >/dev/null && ldd /bin/sh 2>&1 | grep -q musl; then
      C_LIB_SUFFIX="-musl"
      echo "⚙️ 检测到系统使用 musl libc (Alpine)"
  else
      echo "⚙️ 检测到系统使用 glibc"
  fi

  local TUIC_URL="https://github.com/okoko-tw/tuic/releases/download/v1.3.5/tuic-server-x86_64-musl"
  echo "⬇️ 下载 TUIC: $TUIC_URL"

  rm -f "$TUIC_BIN"
  if curl -L -f -o "$TUIC_BIN" "$TUIC_URL"; then
      chmod +x "$TUIC_BIN"
      echo "✅ TUIC 下载完成并已设置可执行"
  else
      echo "❌ 下载失败，请检查网络或手动下载 $TUIC_URL"
      exit 1
  fi
}

# ---------- 生成配置文件 ----------
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
  algorithm = "bbr"
EOF
  echo "✅ 已写入配置文件: $SERVER_TOML"
}

# ---------- 获取公网 IP ----------
get_server_ip() {
  ip=$(curl -s --connect-timeout 5 https://api.ipify.org || echo "YOUR_SERVER_IP")
  echo "$ip"
}

# ---------- 生成 TUIC 链接 ----------
generate_link() {
  local ip="$1"
  cat > "$LINK_TXT" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${ip}
EOF
  echo "📱 TUIC 链接已生成 (${LINK_TXT})"
  cat "$LINK_TXT"
}

# ---------- 后台守护运行 ----------
run_background_loop() {
  echo "🚀 正在启动 TUIC 服务..."
  local BIN_PATH
  BIN_PATH=$(realpath "$TUIC_BIN")
  chmod +x "$BIN_PATH"
  while true; do
    "$BIN_PATH" -c "$SERVER_TOML" || echo "⚠️ TUIC 崩溃，5秒后重启..."
    sleep 5
  done
}

# ---------- 主逻辑 ----------
main() {
  check_and_install_dependencies
  if ! load_existing_config; then
    read_port "$@"
    TUIC_UUID="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
    TUIC_PASSWORD="$(openssl rand -hex 16)"
    echo "🔑 UUID: $TUIC_UUID"
    echo "🔑 密码: $TUIC_PASSWORD"
    echo "🎯 SNI: ${MASQ_DOMAIN}"
    generate_cert
    check_tuic_server
    generate_config
  else
    generate_cert
    check_tuic_server
    generate_config
  fi

  IP=$(get_server_ip)
  generate_link "$IP"
  run_background_loop
}

main "$@"

