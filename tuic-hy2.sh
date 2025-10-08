#!/bin/bash
# TUIC v5 over QUIC 自动部署脚本（支持 Pterodactyl SERVER_PORT + 命令行参数）
set -euo pipefail
IFS=$'\n\t'

MASQ_DOMAIN="www.bing.com"    # 固定伪装域名
SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
LINK_TXT="tuic_link.txt"
TUIC_BIN="./tuic-server"

# ===================== 检测系统并安装 glibc（仅 Alpine） =====================
check_alpine_glibc() {
  if [[ -f /etc/alpine-release ]]; then
    echo "🐧 检测到 Alpine Linux，准备安装 glibc 兼容层..."
    apk add --no-cache wget ca-certificates >/dev/null 2>&1 || true
    wget -q -O /etc/apk/keys/sgerrand.rsa.pub https://alpine-pkgs.sgerrand.com/sgerrand.rsa.pub
    wget -q -O glibc.apk https://github.com/sgerrand/alpine-pkg-glibc/releases/latest/download/glibc-2.35-r0.apk
    if apk add --no-cache glibc.apk >/dev/null 2>&1; then
      echo "✅ glibc 安装完成"
      rm -f glibc.apk
    else
      echo "⚠️ glibc 安装失败，请检查网络或手动安装"
    fi
  else
    echo "✅ 非 Alpine 系统，无需安装 glibc"
  fi
}

# ===================== 检查并安装依赖 =====================
check_dependencies() {
  echo "🔍 检查必要依赖..."
  local deps=("openssl" "curl")
  local missing_deps=()

  for dep in "${deps[@]}"; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      missing_deps+=("$dep")
    fi
  done

  if [[ ${#missing_deps[@]} -gt 0 ]]; then
    echo "❌ 缺少依赖: ${missing_deps[*]}"
    echo "📦 正在安装缺失的依赖..."
    if command -v apk >/dev/null 2>&1; then
      apk add --no-cache "${missing_deps[@]}" >/dev/null 2>&1
    elif command -v apt >/dev/null 2>&1; then
      apt update >/dev/null 2>&1 && apt install -y "${missing_deps[@]}" >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
      yum install -y "${missing_deps[@]}" >/dev/null 2>&1
    else
      echo "❌ 无法自动安装依赖，请手动安装: ${missing_deps[*]}"
      exit 1
    fi
    echo "✅ 依赖安装完成"
  else
    echo "✅ 所有依赖已满足"
  fi

  # 检查 uuidgen
  if ! command -v uuidgen >/dev/null 2>&1; then
    echo "📦 安装 util-linux 以提供 uuidgen..."
    if command -v apk >/dev/null 2>&1; then
      apk add --no-cache util-linux >/dev/null 2>&1
    elif command -v apt >/dev/null 2>&1; then
      apt install -y util-linux >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
      yum install -y util-linux >/dev/null 2>&1
    fi
    echo "✅ util-linux 安装完成"
  fi
}

# ===================== 输入端口或读取环境变量 =====================
read_port() {
  if [[ $# -ge 1 && -n "${1:-}" ]]; then
    TUIC_PORT="$1"
    echo "✅ 从命令行参数读取 TUIC(QUIC) 端口: $TUIC_PORT"
    return
  fi

  if [[ -n "${SERVER_PORT:-}" ]]; then
    TUIC_PORT="$SERVER_PORT"
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
    TUIC_PORT=$(grep '^server =' "$SERVER_TOML" | sed -E 's/.*:(.*)\"/\1/')
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
  TUIC_URL="https://github.com/okoko-tw/tuic/releases/download/v1.3.5/tuic-server-x86_64-musl"
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
initial
