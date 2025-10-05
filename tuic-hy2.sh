#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ===================== 参数解析 =====================
MODE=${1:-both}            # tuic / hysteria2 / both / uninstall
PORT_START=${2:-20000}     # 起始端口
PORT_END=${3:-$PORT_START} # 结束端口（可选）

if [[ "$PORT_START" -gt "$PORT_END" ]]; then
  echo "❌ 起始端口不能大于结束端口"
  exit 1
fi

pick_port() {
  shuf -i "$PORT_START"-"$PORT_END" -n 1
}

SNI="www.bing.com"
ALPN="h3"

install_deps() {
  if command -v apk &>/dev/null; then
    apk add --no-cache curl openssl coreutils bash >/dev/null
  elif command -v apt &>/dev/null; then
    apt update && apt install -y curl openssl coreutils bash >/dev/null
  elif command -v yum &>/dev/null; then
    yum install -y curl openssl coreutils bash >/dev/null
  fi
}

install_deps

IP=$(curl -s --connect-timeout 3 https://api.ipify.org || echo "YOUR_SERVER_IP")

# ===================== TUIC 部署 =====================
deploy_tuic() {
  TUIC_PORT=$(pick_port)
  TUIC_PASS="tuic_$(date +%s | md5sum | head -c 6)"
  CERT_DIR="/etc/tuic"
  BIN="/usr/local/bin/tuic-server"

  mkdir -p "$CERT_DIR"

  # 下载 TUIC 二进制（固定版本 v1.3.5）
  ARCH=$(uname -m)
  if [[ "$ARCH" == "x86_64" ]]; then ARCH="x86_64"; fi
  if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then ARCH="aarch64"; fi

  if [[ ! -x "$BIN" ]]; then
    TUIC_URL="https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-${ARCH}-unknown-linux-musl"
    echo "⏳ 下载 TUIC: $TUIC_URL"
    if ! curl -fL -o "$BIN" "$TUIC_URL"; then
      echo "❌ TUIC 下载失败，请检查 URL"
      exit 1
    fi
    chmod +x "$BIN"
  fi

  # 生成自签证书
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 3650 -keyout "$CERT_DIR/tuic-key.pem" -out "$CERT_DIR/tuic-cert.pem" -subj "/CN=${SNI}"

  # 配置文件
  cat > "$CERT_DIR/config.json" <<EOF
{
  "server": "[::]:${TUIC_PORT}",
  "users": { "auto": "${TUIC_PASS}" },
  "certificate": "${CERT_DIR}/tuic-cert.pem",
  "private_key": "${CERT_DIR}/tuic-key.pem",
  "alpn": ["${ALPN}"],
  "congestion_control": "bbr",
  "disable_sni": false,
  "log_level": "warn"
}
EOF

  # systemd
  cat > /etc/systemd/system/tuicd.service <<EOF
[Unit]
Description=TUIC Server
After=network.target

[Service]
ExecStart=$BIN -c $CERT_DIR/config.json
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable tuicd
  systemctl restart tuicd

  echo "✅ TUIC 已部署并启动"
  echo "节点链接: tuic://${TUIC_PASS}@${IP}:${TUIC_PORT}?sni=${SNI}&alpn=${ALPN}&insecure=true#TUIC"
}

# ===================== Hysteria2 部署 =====================
deploy_hysteria2() {
  HY2_PORT=$(pick_port)
  HY2_PASS="hy2_$(date +%s | md5sum | head -c 6)"
  CERT_DIR="/etc/hysteria2"
  BIN="/usr/local/bin/hysteria2"

  mkdir -p "$CERT_DIR"

  # 下载 Hysteria2 二进制
  ARCH=$(uname -m)
  if [[ "$ARCH" == "x86_64" ]]; then ARCH="amd64"; fi
  if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then ARCH="arm64"; fi

  if [[ ! -x "$BIN" ]]; then
    HY2_URL="https://github.com/apernet/hysteria/releases/download/app/v2.6.3/hysteria-linux-${ARCH}"
    echo "⏳ 下载 Hysteria2: $HY2_URL"
    if ! curl -fL -o "$BIN" "$HY2_URL"; then
      echo "❌ Hysteria2 下载失败，请检查 URL"
      exit 1
    fi
    chmod +x "$BIN"
  fi

  # 生成证书
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 3650 -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" -subj "/CN=${SNI}"

  cat > "$CERT_DIR/server.yaml" <<EOF
listen: ":${HY2_PORT}"
tls:
  cert: "${CERT_DIR}/cert.pem"
  key: "${CERT_DIR}/key.pem"
  alpn:
    - "${ALPN}"
auth:
  type: "password"
  password: "${HY2_PASS}"
bandwidth:
  up: "200mbps"
  down: "200mbps"
quic:
  max_idle_timeout: "10s"
tls_insecure_skip_verify: true
EOF

  # systemd
  cat > /etc/systemd/system/hysteria2d.service <<EOF
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
ExecStart=$BIN server -c $CERT_DIR/server.yaml
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable hysteria2d
  systemctl restart hysteria2d

  echo "✅ Hysteria2 已部署并启动"
  echo "节点链接: hysteria2://${HY2_PASS}@${IP}:${HY2_PORT}?sni=${SNI}&alpn=${ALPN}#Hysteria2"
}

# ===================== 卸载 =====================
uninstall_all() {
  echo "🗑 卸载 TUIC + Hysteria2 ..."
  systemctl stop tuicd 2>/dev/null || true
  systemctl disable tuicd 2>/dev/null || true
  rm -rf /etc/tuic
  rm -f /usr/local/bin/tuic-server
  rm -f /etc/systemd/system/tuicd.service

  systemctl stop hysteria2d 2>/dev/null || true
  systemctl disable hysteria2d 2>/dev/null || true
  rm -rf /etc/hysteria2
  rm -f /usr/local/bin/hysteria2
  rm -f /etc/systemd/system/hysteria2d.service

  systemctl daemon-reload
  echo "✅ 卸载完成"
  exit 0
}

# ===================== 主流程 =====================
case "$MODE" in
  uninstall) uninstall_all ;;
  tuic) deploy_tuic ;;
  hysteria2) deploy_hysteria2 ;;
  both) deploy_tuic && deploy_hysteria2 ;;
  *)
    echo "❌ 模式错误，可选 tuic / hysteria2 / both / uninstall"
    exit 1
    ;;
esac
