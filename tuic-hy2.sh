#!/bin/sh
# =============================================
# TUIC v5 over QUIC 一键部署脚本（增强版）
# 自动检测 curl/bash，下载 tuic-server 并验证 ELF 二进制
# 支持 Alpine / Debian，x86_64 架构
# =============================================

set -e
IFS=$'\n\t'

MASQ_DOMAIN="www.bing.com"
SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
LINK_TXT="tuic_link.txt"
TUIC_BIN="./tuic-server"

# ===================== 检查 curl 和 bash =====================
check_shell_deps() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "⚠️ 未检测到 curl，尝试安装..."
    if [ -f /etc/alpine-release ]; then
      apk add --no-cache curl >/dev/null 2>&1
    elif [ -f /etc/debian_version ]; then
      apt-get update -y >/dev/null 2>&1
      apt-get install -y curl >/dev/null 2>&1
    else
      echo "❌ 无法安装 curl，请手动安装"
      exit 1
    fi
  fi

  if ! command -v bash >/dev/null 2>&1; then
    echo "⚠️ 未检测到 bash，尝试安装..."
    if [ -f /etc/alpine-release ]; then
      apk add --no-cache bash >/dev/null 2>&1
    elif [ -f /etc/debian_version ]; then
      apt-get update -y >/dev/null 2>&1
      apt-get install -y bash >/dev/null 2>&1
    else
      echo "❌ 无法安装 bash，请手动安装"
      exit 1
    fi
  fi
}

# ===================== 检查系统依赖 =====================
check_dependencies() {
  echo "🔍 检查系统环境与依赖..."
  local deps="openssl grep sed coreutils uuidgen"
  local missing=""
  for dep in $deps; do
    command -v "$dep" >/dev/null 2>&1 || missing="$missing $dep"
  done

  if [ -f /etc/alpine-release ]; then
    OS_TYPE="alpine"
    if [ -n "$missing" ]; then apk add --no-cache $missing >/dev/null 2>&1; fi
  elif [ -f /etc/debian_version ]; then
    OS_TYPE="debian"
    if [ -n "$missing" ]; then apt-get update -y >/dev/null 2>&1 && apt-get install -y $missing >/dev/null 2>&1; fi
  else
    OS_TYPE="unknown"
  fi
  echo "🧠 检测到系统类型: $OS_TYPE"
}

# ===================== 输入端口 =====================
read_port() {
  if [ -n "${1:-}" ]; then
    TUIC_PORT="$1"
    echo "✅ 使用端口: $TUIC_PORT"
  else
    printf "请输入端口(1024-65535): "
    read TUIC_PORT
  fi
}

# ===================== 加载已有配置 =====================
load_existing_config() {
  if [ -f "$SERVER_TOML" ]; then
    TUIC_PORT=$(grep '^server =' "$SERVER_TOML" | sed -E 's/.*:(.*)\"/\1/')
    TUIC_UUID=$(grep '^\[users\]' -A1 "$SERVER_TOML" | tail -n1 | awk '{print $1}')
    TUIC_PASSWORD=$(grep '^\[users\]' -A1 "$SERVER_TOML" | tail -n1 | awk -F'"' '{print $2}')
    echo "📂 发现已有配置，自动加载"
    return 0
  fi
  return 1
}

# ===================== 生成证书 =====================
generate_cert() {
  if [ -f "$CERT_PEM" ] && [ -f "$KEY_PEM" ]; then
    echo "🔐 已存在证书，跳过生成"
    return
  fi
  echo "🔐 生成自签 ECDSA 证书..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
}

# ===================== 下载 tuic-server =====================
check_tuic_server() {
  if [ -x "$TUIC_BIN" ]; then
    echo "✅ 已找到 tuic-server"
    if ! file "$TUIC_BIN" | grep -q 'ELF'; then
      echo "❌ tuic-server 不是 ELF 可执行文件，请检查下载 URL"
      exit 1
    fi
    return
  fi

  echo "📥 下载 tuic-server..."
  ARCH=$(uname -m)
  if [ "$ARCH" = "x86_64" ]; then
    TUIC_URL="https://github.com/okoko-tw/tuic/releases/download/v1.3.5/tuic-server-x86_64-musl"
  else
    echo "❌ 暂不支持架构: $ARCH"
    exit 1
  fi

  curl -L -o "$TUIC_BIN" "$TUIC_URL"
  chmod +x "$TUIC_BIN"

  if ! file "$TUIC_BIN" | grep -q 'ELF'; then
    echo "❌ 下载的 tuic-server 不是 ELF 可执行文件，请检查网络或 URL"
    exit 1
  fi
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
certificate = "$CERT_PEM"
private_key = "$KEY_PEM"
alpn = ["h3"]

[quic]
initial_mtu = 1500
controller = "bbr"
EOF
}

# ===================== 获取公网 IP =====================
get_server_ip() {
  curl -s --connect-timeout 3 https://api.ipify.org || echo "YOUR_SERVER_IP"
}

# ===================== 生成链接 =====================
generate_link() {
  ip="$1"
  cat > "$LINK_TXT" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&sni=${MASQ_DOMAIN}&udp_relay_mode=native&allowInsecure=1#TUIC-${ip}
EOF
  echo "📱 TUIC 链接已生成："
  cat "$LINK_TXT"
}

# ===================== 主程序 =====================
main() {
  check_shell_deps
  check_dependencies

  if ! load_existing_config; then
    read_port "$@"
    TUIC_UUID=$(uuidgen)
    TUIC_PASSWORD=$(openssl rand -hex 16)
    generate_cert
    check_tuic_server
    generate_config
  fi

  ip=$(get_server_ip)
  generate_link "$ip"

  echo "✅ 启动 TUIC 服务前验证可执行文件..."
  if ! "$TUIC_BIN" -c "$SERVER_TOML" -h >/dev/null 2>&1; then
    echo "❌ TUIC 服务无法启动，请检查 tuic-server 可执行性"
    exit 1
  fi

  echo "✅ 启动 TUIC 服务中..."
  while true; do
    "$TUIC_BIN" -c "$SERVER_TOML" || echo "⚠️ 进程退出，5秒后重启..."
    sleep 5
  done
}

main "$@"
