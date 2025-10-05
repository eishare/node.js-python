#!/usr/bin/env bash
# ==========================================
# TUIC v5 自动部署脚本（支持 Alpine / Debian / Ubuntu / CentOS）
# 功能：自动检测架构 + 端口随机跳跃 + systemd/OpenRC 自恢复 + 一键卸载
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
RAND_NUM=$(awk 'BEGIN{srand(); print int(rand()*10000)}')
RANDOM_PORT=$((BASE_PORT + RAND_NUM % PORT_RANGE))

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
  echo "⏳ 下载 TUIC 二进制文件: ${TUIC_URL}"
  curl -L -f -o "$TUIC_BIN" "$TUIC_URL" || {
    echo "❌ 下载失败，请检查版本或网络"
    exit 1
  }
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

# ========== 检测系统类型 ==========
detect_init_system() {
  if command -v systemctl >/dev/null 2>&1; then
    echo "systemd"
  elif [ -d /etc/init.d ]; then
    echo "openrc"
  else
    echo "unknown"
  fi
}

# ========== systemd/OpenRC 自恢复 ==========
install_service() {
  INIT_SYS=$(detect_init_system)
  if [ "$INIT_SYS" = "systemd" ]; then
    mkdir -p /etc/systemd/system
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
    echo "✅ TUIC 服务已启动 (systemd)"
  elif [ "$INIT_SYS" = "openrc" ]; then
cat > /etc/init.d/${SERVICE_NAME} <<EOF
#!/sbin/openrc-run
command="${TUIC_BIN}"
command_args="-c $(pwd)/${SERVER_TOML}"
pidfile="/var/run/${SERVICE_NAME}.pid"
EOF
    chmod +x /etc/init.d/${SERVICE_NAME}
    rc-update add ${SERVICE_NAME} default
    rc-service ${SERVICE_NAME} restart
    echo "✅ TUIC 服务已启动 (OpenRC)"
  else
    echo "⚠️ 未检测到 systemd 或 openrc，直接前台运行 TUIC"
    nohup "${TUIC_BIN}" -c "$(pwd)/${SERVER_TOML}" >/dev/null 2>&1 &
  fi
}

# ========== 一键卸载 ==========
uninstall_tuic() {
  echo "⚙️ 正在卸载 TUIC..."
  INIT_SYS=$(detect_init_system)
  if [ "$INIT_SYS" = "systemd" ]; then
    systemctl stop ${SERVICE_NAME} || true
    systemctl disable ${SERVICE_NAME} || true
    rm -f /etc/systemd/system/${SERVICE_NAME}.service
    systemctl daemon-reload
  elif [ "$INIT_SYS" = "openrc" ]; then
    rc-service ${SERVICE_NAME} stop || true
    rc-update del ${SERVICE_NAME} || true
    rm -f /etc/init.d/${SERVICE_NAME}
  fi
  rm -f "$TUIC_BIN" "$SERVER_TOML" "$CERT_PEM" "$KEY_PEM" "$LINK_TXT"
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
  echo "tuic://${UUID}:${PASSWORD}@${IP}:${RANDOM_PORT}?sni=${MASQ_DOMAIN}&allowInsecure=1#TUIC-${IP}" > "$LINK_TXT"
  echo "📄 节点信息："
  cat "$LINK_TXT"
}

# ========== 主逻辑 ==========
if [ "$1" = "uninstall" ]; then
  uninstall_tuic
else
  download_tuic
  generate_cert
  generate_config
  install_service
  generate_link
fi
