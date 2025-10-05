#!/usr/bin/env bash
# ==========================================
# TUIC v5 自动部署脚本（支持 Alpine / Debian / Ubuntu / CentOS）
# 功能：自动检测架构 + 端口随机跳跃 + systemd 守护 + 一键卸载
# 作者：Eishare 修改版
# ==========================================

set -e

MASQ_DOMAIN="www.bing.com"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
SERVER_TOML="server.toml"
LINK_TXT="tuic_link.txt"
TUIC_BIN="/usr/local/bin/tuic-server"
SERVICE_NAME="tuic-server"

# ========== 端口逻辑 ==========
BASE_PORT="${1:-10000}"
PORT_RANGE="${2:-200}"
RANDOM_PORT=$((BASE_PORT + RANDOM % PORT_RANGE))

# ========== 下载 TUIC ==========
download_tuic() {
  if [[ -x "$TUIC_BIN" ]]; then
    echo "✅ TUIC 已安装: $TUIC_BIN"
    return
  fi

  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|amd64) ARCH_NAME="x86_64-unknown-linux-musl" ;;
    aarch64|arm64) ARCH_NAME="aarch64-unknown-linux-musl" ;;
    *) echo "❌ 不支持的架构: $ARCH"; exit 1 ;;
  esac

  TUIC_URL="https://github.com/EAimTY/tuic/releases/latest/download/tuic-server-${ARCH_NAME}"
  echo "⏳ 正在下载 TUIC 二进制文件..."
  curl -L -f -o "$TUIC_BIN" "$TUIC_URL"
  chmod +x "$TUIC_BIN"
  echo "✅ TUIC 下载完成: $TUIC_BIN"
}

# ========== 生成证书 ==========
generate_cert() {
  if [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]]; then
    echo "🔐 已检测到证书，跳过生成"
    return
  fi
  echo "🔐 生成自签名证书 (${MASQ_DOMAIN})..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -days 3650 -nodes -subj "/CN=${MASQ_DOMAIN}"
  chmod 600 "$KEY_PEM"
  chmod 644 "$CERT_PEM"
  echo "✅ 证书生成成功"
}

# ========== 生成配置文件 ==========
generate_config() {
  UUID=$(cat /proc/sys/kernel/random/uuid)
  PASSWORD=$(openssl rand -hex 16)

cat > "$SERVER_TOML" <<EOF
log_level = "warn"
server = "0.0.0.0:${RANDOM_PORT}"

[users]
${UUID} = "${PASSWORD}"

[tls]
certificate = "${CERT_PEM}"
private_key = "${KEY_PEM}"
alpn = ["h3"]

[quic]
congestion_control = "bbr"
EOF

  echo "✅ TUIC 配置已生成: 端口 ${RANDOM_PORT}"
}

# ========== systemd 自恢复 ==========
install_systemd() {
cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=TUIC Server Service
After=network.target

[Service]
ExecStart=${TUIC_BIN} -c $(pwd)/${SERVER_TOML}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable ${SERVICE_NAME}
  systemctl restart ${SERVICE_NAME}
  echo "✅ TUIC 服务已启动并设为开机自启"
}

# ========== 一键卸载 ==========
uninstall_tuic() {
  echo "⚙️ 正在卸载 TUIC..."
  systemctl stop ${SERVICE_NAME} || true
  systemctl disable ${SERVICE_NAME} || true
  rm -f /etc/systemd/system/${SERVICE_NAME}.service
  rm -f "$TUIC_BIN" "$SERVER_TOML" "$CERT_PEM" "$KEY_PEM" "$LINK_TXT"
  systemctl daemon-reload
  echo "✅ 已卸载 TUIC 并清理所有文件"
  exit 0
}

# ========== 获取公网 IP ==========
get_ip() {
  curl -s https://api.ipify.org || echo "YOUR_SERVER_IP"
}

# ========== 生成节点链接 ==========
generate_link() {
  IP=$(get_ip)
  echo "tuic://${UUID}:${PASSWORD
