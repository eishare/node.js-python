#!/bin/bash
# ===========================================
# Argo + VLESS(WS+TLS) + TUIC v5 自动部署脚本
# ✅ 支持非 root 环境
# ✅ 兼容 Alpine / Debian / Ubuntu / CentOS
# ===========================================
set -euo pipefail
IFS=$'\n\t'

MASQ_DOMAIN="www.bing.com"
LINK_TXT="links.txt"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
SERVER_TOML="server.toml"
XRAY_BIN="./xray"
TUIC_BIN="./tuic-server"
ARGO_BIN="./cloudflared"
LOG_FILE="argo.log"

# -------------------- 检查依赖 --------------------
install_deps() {
  echo "📦 检查依赖..."
  if ! command -v curl &>/dev/null; then
    echo "⚠️ 缺少 curl，请手动安装"
  fi
  if ! command -v openssl &>/dev/null; then
    echo "⚠️ 缺少 openssl，请手动安装"
  fi
  if ! command -v unzip &>/dev/null; then
    echo "⚠️ 缺少 unzip，请手动安装"
  fi
}

# -------------------- 获取TUIC端口 --------------------
read_port() {
  if [[ $# -ge 1 && -n "${1:-}" ]]; then
    TUIC_PORT="$1"
  elif [[ -n "${SERVER_PORT:-}" ]]; then
    TUIC_PORT="$SERVER_PORT"
  else
    read -rp "⚙️ 请输入 TUIC 端口 (1024-65535): " TUIC_PORT
  fi
  echo "✅ TUIC 端口: $TUIC_PORT"
}

# -------------------- 下载程序 --------------------
download_binaries() {
  echo "📥 下载核心文件中..."
  [[ ! -x "$XRAY_BIN" ]] && curl -L -o xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip && unzip -o xray.zip && chmod +x xray && mv xray "$XRAY_BIN"
  [[ ! -x "$TUIC_BIN" ]] && curl -L -o "$TUIC_BIN" https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-x86_64-linux && chmod +x "$TUIC_BIN"
  [[ ! -x "$ARGO_BIN" ]] && curl -L -o "$ARGO_BIN" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 && chmod +x "$ARGO_BIN"
  echo "✅ 所有组件已下载"
}

# -------------------- TUIC配置 --------------------
setup_tuic() {
  echo "🔐 生成 TUIC 证书..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
  chmod 600 "$KEY_PEM"; chmod 644 "$CERT_PEM"

  TUIC_UUID=$(cat /proc/sys/kernel/random/uuid)
  TUIC_PASSWORD=$(openssl rand -hex 16)

  cat > "$SERVER_TOML" <<EOF
log_level = "off"
server = "
