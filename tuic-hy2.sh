#!/bin/sh
# =============================================
# TUIC v5 over QUIC 一键部署脚本（增强版，带自动验证下载）
# 适用于 Alpine / Debian，x86_64
# =============================================

MASQ_DOMAIN="www.bing.com"
SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
LINK_TXT="tuic_link.txt"
TUIC_BIN="./tuic-server"

# ===================== 检查并安装 curl/bash =====================
check_shell_deps() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "⚠️ curl 未安装，尝试安装..."
    if [ -f /etc/alpine-release ]; then
      apk add --no-cache curl >/dev/null 2>&1
    elif [ -f /etc/debian_version ]; then
      apt-get update -y >/dev/null 2>&1
      apt-get install -y curl >/dev/null 2>&1
    else
      echo "❌ 无法自动安装 curl，请手动安装"
      exit 1
    fi
  fi

  if ! command -v bash >/dev/null 2>&1; then
    echo "⚠️ bash 未安装，尝试安装..."
    if [ -f /etc/alpine-release ]; then
      apk add --no-cache bash >/dev/null 2>&1
    elif [ -f /etc/debian_version ]; then
      apt-get update -y >/dev/null 2>&1
      apt-get install -y bash >/dev/null 2>&1
    else
      echo "❌ 无法自动安装 bash，请手动安装"
      exit 1
    fi
  fi
}

# ===================== 检查系统依赖 =====================
check_dependencies() {
  echo "🔍 检查系统环境与依赖..."
  deps="openssl grep sed coreutils uuidgen"
  missing=""
  for dep in $deps; do
    command -v "$dep" >/dev/null 2>&1 || missing="$missing $dep"
  done

  if [ -f /etc/alpine-release ]; then
    OS_TYPE="alpine"
    if [ -n "$missing" ]; then
      apk add --no-cache $missing >/dev/null 2>&1
    fi
  elif [ -f /etc/debian_version ]; then
    OS_TYPE="debian"
    if [ -n "$missing" ]; then
      apt-get update -y >/dev/null 2>&1
      apt-get install -y $missing >/dev/null 2>&1
    fi
  else
    OS_TYPE="unknown"
  fi
  echo "🧠 检测到系统类型: $OS_TYPE"
}

# ===================== 读取端口 =====================
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

# ===================== 下载 tuic-server (自动验证) =====================
check_tuic_server() {
  if [ -x "$TUIC_BIN" ]; then
    if file "$TUIC_BIN" | grep -q 'ELF'; then
      echo "✅ 已存在可执行 tuic-server"
      return
    fi
    echo "⚠️ tuic-server 不是 ELF，可重新下载"
    rm -f "$TUIC_BIN"
  fi

  ARCH=$(uname -m)
  if [ "$ARCH" != "x86_64" ]; then
    echo "❌ 暂不支持架构: $ARCH"
    exit 1
  fi

  TUIC_URL="https://github.com/okoko-tw/tuic/releases/download/v1.3.5/tuic-server-x86_64-musl"
  echo "📥 下载 tuic-server..."
  tries=0
  while [ $tries -lt 3 ]; do
    tries=$((tries+1))
    curl -L -o "$TUIC_BIN" "$TUIC_URL"
    chmod +x "$TUIC_BIN"
    size=$(stat -c %s "$TUIC_BIN" 2>/dev/null || echo 0)
    if [ "$size" -gt 100000 ] && file "$TUIC_BIN" | grep -q 'ELF'; then
      echo "✅ tuic-server 下载成功"
      return
    fi
    echo "⚠️ 下载失败或文件无效，重试 ($tries/3)..."
    rm -f "$TUIC_BIN"
    sleep 2
  done

  echo "❌ tuic-server 下载失败，请检查网络或 URL"
  exit 1
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

# ===================== 生成 TUIC 链接 =====================
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

  echo "✅ 启动 TUIC 服务中..."
  while true; do
    "$TUIC_BIN" -c "$SERVER_TOML" || echo "⚠️ 进程退出，5秒后重启..."
    sleep 5
  done
}

main "$@"
