#!/bin/bash
# =============================================
# TUIC v5 over QUIC 一键部署脚本（支持 Alpine / Debian）
# 自动检测 Alpine 并安装 glibc 兼容层
# =============================================

set -euo pipefail
IFS=$'\n\t'

MASQ_DOMAIN="www.bing.com"  # 伪装域名
SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
LINK_TXT="tuic_link.txt"
TUIC_BIN="./tuic-server"

# ===================== 检查并安装依赖 =====================
check_dependencies() {
  echo "🔍 检查系统环境与依赖..."
  local deps=("openssl" "curl" "grep" "sed" "coreutils")
  local missing=()

  for dep in "${deps[@]}"; do
    command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
  done

  # 检测系统类型
  if grep -qi 'alpine' /etc/os-release 2>/dev/null; then
    OS_TYPE="alpine"
  elif grep -qi 'debian' /etc/os-release 2>/dev/null || grep -qi 'ubuntu' /etc/os-release 2>/dev/null; then
    OS_TYPE="debian"
  elif grep -qi 'centos' /etc/os-release 2>/dev/null || grep -qi 'rocky' /etc/os-release 2>/dev/null; then
    OS_TYPE="centos"
  else
    OS_TYPE="unknown"
  fi

  echo "🧠 检测到系统类型: $OS_TYPE"

  # 安装缺失依赖
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "📦 正在安装依赖: ${missing[*]}"
    case "$OS_TYPE" in
      alpine)
        apk add --no-cache "${missing[@]}" >/dev/null 2>&1 || true
        ;;
      debian)
        apt-get update -y >/dev/null 2>&1
        apt-get install -y "${missing[@]}" >/dev/null 2>&1 || true
        ;;
      centos)
        yum install -y "${missing[@]}" >/dev/null 2>&1 || true
        ;;
      *)
        echo "⚠️ 无法识别的系统，请手动安装依赖: ${missing[*]}"
        ;;
    esac
  fi

  # 安装 uuidgen
  if ! command -v uuidgen >/dev/null 2>&1; then
    echo "📦 安装 util-linux..."
    case "$OS_TYPE" in
      alpine) apk add --no-cache util-linux >/dev/null 2>&1 ;;
      debian) apt-get install -y util-linux >/dev/null 2>&1 ;;
      centos) yum install -y util-linux >/dev/null 2>&1 ;;
    esac
  fi

  # 如果是 Alpine，安装 glibc 兼容层
  if [[ "$OS_TYPE" == "alpine" ]]; then
    echo "🔧 检查 glibc 兼容层..."
    if ! ls /lib/libc.musl* >/dev/null 2>&1; then
      echo "⚠️ 未检测到 musl glibc 文件，可能是非标准 Alpine 环境。"
    fi
    if ! ls /usr/glibc-compat/lib/libc.so.6 >/dev/null 2>&1; then
      echo "📥 安装 glibc 兼容层..."
      wget -q -O /etc/apk/keys/sgerrand.rsa.pub https://alpine-pkgs.sgerrand.com/sgerrand.rsa.pub
      GLIBC_VER="2.35-r0"
      wget -q https://github.com/sgerrand/alpine-pkg-glibc/releases/download/${GLIBC_VER}/glibc-${GLIBC_VER}.apk
      apk add --force-overwrite --no-cache glibc-${GLIBC_VER}.apk >/dev/null 2>&1 || true
      rm -f glibc-${GLIBC_VER}.apk
    fi
  fi

  echo "✅ 依赖检查完成"
}

# ===================== 输入端口 =====================
read_port() {
  if [[ $# -ge 1 && -n "${1:-}" ]]; then
    TUIC_PORT="$1"
    echo "✅ 使用端口: $TUIC_PORT"
    return
  fi
  read -rp "请输入端口(1024-65535): " TUIC_PORT
}

# ===================== 加载已有配置 =====================
load_existing_config() {
  if [[ -f "$SERVER_TOML" ]]; then
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
  if [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]]; then
    echo "🔐 已存在证书，跳过生成"
    return
  fi
  echo "🔐 生成自签 ECDSA 证书..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
}

# ===================== 下载 tuic-server =====================
check_tuic_server() {
  if [[ -x "$TUIC_BIN" ]]; then
    echo "✅ 已找到 tuic-server"
    return
  fi
  echo "📥 下载 tuic-server..."
  ARCH=$(uname -m)
  if [[ "$ARCH" == "x86_64" ]]; then
    TUIC_URL="https://github.com/okoko-tw/tuic/releases/download/v1.3.5/tuic-server-x86_64-musl"
  else
    echo "❌ 暂不支持架构: $ARCH"
    exit 1
  fi
  curl -L -o "$TUIC_BIN" "$TUIC_URL"
  chmod +x "$TUIC_BIN"
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
  local ip="$1"
  cat > "$LINK_TXT" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&sni=${MASQ_DOMAIN}&udp_relay_mode=native&allowInsecure=1#TUIC-${ip}
EOF
  echo "📱 TUIC 链接已生成："
  cat "$LINK_TXT"
}

# ===================== 主程序 =====================
main() {
  check_dependencies
  if ! load_existing_config; then
    read_port "$@"
    TUIC_UUID="$(uuidgen)"
    TUIC_PASSWORD="$(openssl rand -hex 16)"
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
