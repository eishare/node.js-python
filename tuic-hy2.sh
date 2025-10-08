#!/bin/bash
# TUIC v5 over QUIC 自动部署脚本
# 兼容：Alpine (使用 Musl 版本), Ubuntu/Debian (使用 Glibc 版本)
set -euo pipefail
IFS=$'\n\t'

# ===================== 全局配置 =====================
MASQ_DOMAIN="www.bing.com"    # 固定伪装域名
SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
LINK_TXT="tuic_link.txt"
TUIC_BIN="./tuic-server"
TUIC_VERSION="1.5.2"

# ----------------------------------------------------

# 检查系统类型并安装依赖
check_and_install_dependencies() {
    local ID
    ID=$(grep -E '^(ID)=' /etc/os-release 2>/dev/null | awk -F= '{print $2}' | sed 's/"//g' || echo "unknown")

    echo "🔍 正在检测系统 ($ID) 并安装依赖..."

    # 统一安装 curl 和 openssl
    if command -v apk >/dev/null; then
        # Alpine Linux
        apk update >/dev/null
        apk add curl openssl util-linux || { echo "❌ Alpine依赖安装失败"; exit 1; }
    elif command -v apt >/dev/null; then
        # Debian/Ubuntu
        apt update -qq >/dev/null
        apt install -y curl openssl uuid-runtime >/dev/null
    elif command -v yum >/dev/null; then
        # CentOS/Fedora
        yum install -y curl openssl uuid
    else
        echo "⚠️ 无法自动安装依赖。请确保已安装 curl, openssl, uuidgen。"
    fi
    echo "✅ 依赖检查/安装完成。"
}

# ----------------------------------------------------

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
    # 使用 awk 来更稳定地提取端口和用户
    TUIC_PORT=$(grep '^server =' "$SERVER_TOML" | sed -E 's/.*:(.*)\"/\1/' || echo "")
    TUIC_UUID=$(grep '^\[users\]' -A1 "$SERVER_TOML" | tail -n1 | awk '{print $1}' || echo "")
    TUIC_PASSWORD=$(grep '^\[users\]' -A1 "$SERVER_TOML" | tail -n1 | awk -F'"' '{print $2}' || echo "")
    
    # 仅在提取到有效信息时才算成功加载
    if [[ -n "$TUIC_PORT" && -n "$TUIC_UUID" && -n "$TUIC_PASSWORD" ]]; then
      echo "📂 检测到已有配置，加载中..."
      echo "✅ 端口: $TUIC_PORT"
      echo "✅ UUID: $TUIC_UUID"
      echo "✅ 密码: $TUIC_PASSWORD"
      return 0
    fi
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
  # 兼容性修复: 确保 openssl 命令正确运行
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1 || {
        echo "❌ OpenSSL 证书生成失败。"
        exit 1
    }
  chmod 600 "$KEY_PEM"
  chmod 644 "$CERT_PEM"
  echo "✅ 自签证书生成完成"
}

# ===================== 检查并下载 tuic-server (核心修复) =====================
check_tuic_server() {
  
  # 1. 强制清理：如果文件存在，删除它以确保下载的是兼容 Musl/Glibc 的正确版本。
  if [[ -f "$TUIC_BIN" ]]; then
    echo "⚠️ 检测到 tuic-server 文件，将强制删除并重新下载以确保 Musl/Glibc 兼容性..."
    rm -f "$TUIC_BIN"
  fi

  # 2. 检查是否已找到且可执行 (通常在 rm 后不成立，除非用户手动放置)
  if [[ -x "$TUIC_BIN" ]]; then
    echo "✅ 已找到 tuic-server (二次确认)"
    return
  fi
  
  echo "📥 未找到 tuic-server，正在下载..."

  # 3. 检测架构
  ARCH=$(uname -m)
  case "$ARCH" in
      x86_64|amd64)
          ARCH="x86_64"
          ;;
      aarch64|arm64)
          ARCH="aarch64"
          ;;
      *)
          echo "❌ 暂不支持架构: $ARCH"
          exit 1
          ;;
  esac

  # 4. 确定 C 库类型 (Glibc 或 Musl)
  # Alpine 使用 /lib/ld-musl-*.so.1，其他常用系统使用 /lib/ld-linux-*.so.2 或 /lib/ld-linux-aarch64.so.1
  local C_LIB_SUFFIX=""
  if ldd /bin/sh 2>&1 | grep -q 'musl'; then
      echo "⚙️ 系统检测为 Musl (Alpine)"
      C_LIB_SUFFIX="-musl"
  else
      echo "⚙️ 系统检测为 Glibc (Ubuntu/Debian)"
  fi
  
  # 5. 构造下载 URL
  local TUIC_URL="https://github.com/Itsusinn/tuic/releases/download/v${TUIC_VERSION}/tuic-server-${ARCH}-linux${C_LIB_SUFFIX}"
  echo "⬇️ 目标下载链接: $TUIC_URL"

  # 6. 下载
  if curl -L -f -o "$TUIC_BIN" "$TUIC_URL"; then
    chmod +x "$TUIC_BIN"
    echo "✅ tuic-server 下载完成"
  else
    echo "❌ 下载失败 (Curl Exit Code: $?)，请检查网络或手动下载 $TUIC_URL"
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
initial_window = 4194304
EOF
}

# ===================== 获取公网 IP =====================
get_server_ip() {
  # 统一使用 ipify，增强兼容性
  ip=$(curl -s --connect-timeout 5 https://api.ipify.org || true)
  echo "${ip:-YOUR_SERVER_IP}"
}

# ===================== 生成 TUIC 链接 =====================
generate_link() {
  local ip="$1"
  cat > "$LINK_TXT" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${ip}
EOF

  echo ""
  echo "📱 TUIC 链接已生成并保存到 $LINK_TXT"
  echo "🔗 链接内容："
  cat "$LINK_TXT"
  echo ""
}

# ===================== 后台循环守护 =====================
run_background_loop() {
  echo "✅ 服务已启动，tuic-server 正在运行..."
  
  # 确保当前目录可执行
  local FULL_BIN_PATH
  FULL_BIN_PATH=$(realpath "$TUIC_BIN")
  
  if ! [[ -x "$FULL_BIN_PATH" ]]; then
    echo "❌ 致命错误：执行文件 ($FULL_BIN_PATH) 权限不足或文件系统错误。"
    exit 1
  fi
  
  while true; do
    "$FULL_BIN_PATH" -c "$SERVER_TOML"
    echo "⚠️ tuic-server 已退出，5秒后重启..."
    sleep 5
  done
}

# ===================== 主逻辑 =====================
main() {
  check_and_install_dependencies

  if ! load_existing_config; then
    echo "⚙️ 第一次运行，开始初始化..."
    read_port "$@"
    # 使用 uuidgen 命令 (依赖 util-linux 或 uuid-runtime)
    TUIC_UUID="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)"
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
  fi

  ip="$(get_server_ip)"
  generate_link "$ip"
  run_background_loop
}

main "$@"
