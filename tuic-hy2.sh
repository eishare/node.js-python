#!/bin/sh
# =============================================
# TUIC v5 智能一键部署脚本（自动识别系统架构 & libc）
# 作者: Eishare
# =============================================

set -e

MASQ_DOMAIN="www.bing.com"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
CONF="server.toml"
LINK_TXT="tuic_link.txt"
TUIC_BIN="./tuic-server"

# ===================== 函数定义 =====================

log() { echo "[$(date '+%H:%M:%S')] $*"; }

install_deps() {
  log "🔍 检查依赖中..."
  if ! command -v curl >/dev/null 2>&1; then
    log "📦 安装 curl..."
    if command -v apt >/dev/null 2>&1; then apt update -y && apt install -y curl;
    elif command -v apk >/dev/null 2>&1; then apk add --no-cache curl;
    elif command -v yum >/dev/null 2>&1; then yum install -y curl;
    fi
  fi

  if ! command -v openssl >/dev/null 2>&1; then
    log "📦 安装 openssl..."
    if command -v apt >/dev/null 2>&1; then apt install -y openssl;
    elif command -v apk >/dev/null 2>&1; then apk add --no-cache openssl;
    elif command -v yum >/dev/null 2>&1; then yum install -y openssl;
    fi
  fi

  if ! command -v uuidgen >/dev/null 2>&1; then
    log "📦 安装 util-linux..."
    if command -v apt >/dev/null 2>&1; then apt install -y uuid-runtime;
    elif command -v apk >/dev/null 2>&1; then apk add --no-cache util-linux;
    elif command -v yum >/dev/null 2>&1; then yum install -y util-linux;
    fi
  fi
  log "✅ 依赖检查完成"
}

detect_arch_libc() {
  ARCH=$(uname -m)
  if ldd --version 2>&1 | grep -qi musl; then
    LIBC="musl"
  else
    LIBC="glibc"
  fi
  log "🧠 检测系统架构: $ARCH | libc: $LIBC"

  case "$ARCH" in
    x86_64)
      if [ "$LIBC" = "musl" ]; then
        TUIC_URL="https://github.com/EAimTY/tuic/releases/download/0.8.5/tuic-server-x86_64-unknown-linux-musl"
      else
        TUIC_URL="https://github.com/EAimTY/tuic/releases/download/0.8.5/tuic-server-x86_64-unknown-linux-gnu"
      fi
      ;;
    aarch64)
      TUIC_URL="https://github.com/EAimTY/tuic/releases/download/0.8.5/tuic-server-aarch64-unknown-linux-musl"
      ;;
    armv7l)
      TUIC_URL="https://github.com/EAimTY/tuic/releases/download/0.8.5/tuic-server-armv7-unknown-linux-musleabihf"
      ;;
    *)
      log "❌ 不支持的架构: $ARCH"
      exit 1
      ;;
  esac
}

gen_cert() {
  if [ ! -f "$CERT_PEM" ] || [ ! -f "$KEY_PEM" ]; then
    log "🔐 生成自签 ECDSA 证书..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=$MASQ_DOMAIN" -days 365 -nodes >/dev/null 2>&1
    log "✅ 自签证书生成完成"
  else
    log "🔐 已存在证书，跳过生成"
  fi
}

download_tuic() {
  if [ -x "$TUIC_BIN" ]; then
    log "✅ 已存在 tuic-server"
    return
  fi
  log "📥 未找到 tuic-server，正在下载..."
  for i in 1 2 3; do
    curl -L --retry 3 -o "$TUIC_BIN" "$TUIC_URL" && break
    log "⚠️ 下载失败，重试 ($i/3)..."
    sleep 2
  done
  chmod +x "$TUIC_BIN" || true

  # 校验大小是否合理
  SIZE=$(wc -c <"$TUIC_BIN")
  if [ "$SIZE" -lt 1000000 ]; then
    log "❌ tuic-server 文件异常（大小过小: $SIZE 字节）"
    rm -f "$TUIC_BIN"
    exit 1
  fi
  log "✅ tuic-server 下载完成（$((SIZE/1024)) KB）"
}

gen_config() {
  UUID=$(uuidgen)
  PASS=$(openssl rand -hex 16)
  PORT="$1"

  cat > "$CONF" <<EOF
log_level = "info"
server = "0.0.0.0:${PORT}"
udp_relay_ipv6 = false
zero_rtt_handshake = true
auth_timeout = "10s"
task_negotiation_timeout = "5s"
gc_interval = "10s"
gc_lifetime = "10s"
max_external_packet_size = 8192

[users]
${UUID} = "${PASS}"

[tls]
certificate = "${CERT_PEM}"
private_key = "${KEY_PEM}"
alpn = ["h3"]

[quic]
initial_mtu = 1500
congestion_control = "bbr"
EOF

  log "✅ TUIC 配置文件生成完成"

  IP=$(curl -s https://api.ipify.org || echo "YOUR_IP")
  LINK="tuic://${UUID}:${PASS}@${IP}:${PORT}?congestion_control=bbr&alpn=h3&sni=${MASQ_DOMAIN}&udp_relay_mode=native&allowInsecure=1#TUIC-${IP}"
  echo "$LINK" > "$LINK_TXT"

  log "📱 TUIC 链接已生成："
  echo "$LINK"
}

start_tuic() {
  log "🚀 启动 TUIC 服务中..."
  chmod +x "$TUIC_BIN"
  nohup "$TUIC_BIN" -c "$CONF" >/dev/null 2>&1 &
  sleep 1
  pgrep -x tuic-server >/dev/null && log "✅ TUIC 服务已启动" || log "❌ 启动失败，请检查日志或架构兼容性"
}

# ===================== 主逻辑 =====================
PORT="${1:-4433}"

log "⚙️ 开始安装 TUIC QUIC 服务..."
install_deps
detect_arch_libc
gen_cert
download_tuic
gen_config "$PORT"
start_tuic
