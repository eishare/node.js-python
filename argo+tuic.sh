#!/bin/bash
# ================================================
# Argo + VLESS(WS+TLS) + TUIC v5 自动部署脚本
# 兼容: Alpine / Debian / Ubuntu / CentOS
# ================================================
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

# -------------------- 环境依赖 --------------------
install_deps() {
  echo "📦 检查并安装依赖..."
  if command -v apk &>/dev/null; then
    apk add --no-cache curl unzip openssl
  elif command -v apt &>/dev/null; then
    apt update -y && apt install -y curl unzip openssl
  elif command -v yum &>/dev/null; then
    yum install -y curl unzip openssl
  else
    echo "❌ 不支持的系统"
    exit 1
  fi
}

# -------------------- 获取TUIC端口 --------------------
read_port() {
  if [[ $# -ge 1 && -n "${1:-}" ]]; then
    TUIC_PORT="$1"
    echo "✅ 从命令行读取 TUIC 端口: $TUIC_PORT"
  elif [[ -n "${SERVER_PORT:-}" ]]; then
    TUIC_PORT="$SERVER_PORT"
    echo "✅ 从环境变量读取 TUIC 端口: $TUIC_PORT"
  else
    read -rp "⚙️ 请输入 TUIC 端口 (1024-65535): " TUIC_PORT
  fi
}

# -------------------- 下载程序 --------------------
download_binaries() {
  echo "📥 下载核心文件中..."
  [[ ! -x "$XRAY_BIN" ]] && curl -L -o "$XRAY_BIN" https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip && unzip -o Xray-linux-64.zip && chmod +x xray && mv xray "$XRAY_BIN"
  [[ ! -x "$TUIC_BIN" ]] && curl -L -o "$TUIC_BIN" https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-x86_64-linux && chmod +x "$TUIC_BIN"
  [[ ! -x "$ARGO_BIN" ]] && curl -L -o "$ARGO_BIN" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 && chmod +x "$ARGO_BIN"
  echo "✅ 所有组件已就绪"
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
server = "0.0.0.0:${TUIC_PORT}"
[users]
${TUIC_UUID} = "${TUIC_PASSWORD}"
[tls]
certificate = "$CERT_PEM"
private_key = "$KEY_PEM"
alpn = ["h3"]
[quic]
congestion_control = "bbr"
EOF
}

# -------------------- Xray + Argo配置 --------------------
setup_argo_vless() {
  UUID=$(cat /proc/sys/kernel/random/uuid)
  cat > config.json <<EOF
{
  "inbounds": [{
    "port": 443,
    "protocol": "vless",
    "settings": {"clients": [{"id": "$UUID"}], "decryption": "none"},
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "tlsSettings": {"alpn": ["h2","http/1.1"], "certificates": [{"certificateFile": "$CERT_PEM", "keyFile": "$KEY_PEM"}]},
      "wsSettings": {"path": "/"}
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
}

# -------------------- 启动服务 --------------------
run_services() {
  echo "🚀 启动 Xray + TUIC + Argo 隧道..."
  nohup "$XRAY_BIN" run -c config.json >/dev/null 2>&1 &
  nohup "$TUIC_BIN" -c "$SERVER_TOML" >/dev/null 2>&1 &
  nohup "$ARGO_BIN" tunnel --url https://localhost:443 --no-autoupdate > "$LOG_FILE" 2>&1 &
  sleep 8
}

# -------------------- 生成节点链接 --------------------
generate_links() {
  local argo_domain
  argo_domain=$(grep -oE "https://.*trycloudflare.com" "$LOG_FILE" | head -n1 | sed 's@https://@@')
  ip=$(curl -s https://api.ipify.org || echo "YOUR_IP")

  echo "🔗 生成节点链接中..."
  {
    echo "=== TUIC ==="
    echo "tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&sni=${MASQ_DOMAIN}#TUIC-${ip}"
    echo
    echo "=== VLESS (Argo WS+TLS) ==="
    echo "vless://${UUID}@${argo_domain}:443?encryption=none&security=tls&sni=${MASQ_DOMAIN}&type=ws&path=/#Argo-${argo_domain}"
  } > "$LINK_TXT"

  echo "✅ 节点信息已保存到 $LINK_TXT"
  echo "📜 Argo 临时域名: https://${argo_domain}"
}

# -------------------- 主逻辑 --------------------
main() {
  install_deps
  read_port "$@"
  download_binaries
  setup_tuic
  setup_argo_vless
  run_services
  generate_links
  echo "✅ 所有服务已部署完成"
  echo "📝 查看日志: cat $LOG_FILE"
  echo "🔗 查看节点: cat $LINK_TXT"
}

main "$@"
