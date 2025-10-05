#!/bin/sh
set -euo pipefail
IFS=$'\n\t'

MODE=${1:-deploy}          # deploy / uninstall
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
BIN_DIR="$HOME/bin"
mkdir -p "$BIN_DIR"
BIN="$BIN_DIR/tuic-server"
CERT_DIR="$HOME/.tuic"

install_deps() {
  if command -v apk &>/dev/null; then
    apk add --no-cache curl openssl coreutils bash >/dev/null
  elif command -v apt &>/dev/null; then
    sudo apt update && sudo apt install -y curl openssl coreutils bash >/dev/null
  elif command -v yum &>/dev/null; then
    sudo yum install -y curl openssl coreutils bash >/dev/null
  fi
}

install_deps

IP=$(curl -s --connect-timeout 3 https://api.ipify.org || echo "YOUR_SERVER_IP")

deploy_tuic() {
  PORT=$(pick_port)
  PASS="tuic_$(date +%s | md5sum | head -c6)"
  mkdir -p "$CERT_DIR"

  # 下载 TUIC 二进制
  ARCH=$(uname -m)
  [[ "$ARCH" == "x86_64" ]] && ARCH="x86_64"
  [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && ARCH="aarch64"

  if [[ ! -x "$BIN" ]]; then
    URL="https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-${ARCH}-unknown-linux-musl"
    echo "⏳ 下载 TUIC: $URL"
    curl -fL -o "$BIN" "$URL"
    chmod +x "$BIN"
  fi

  # 生成自签证书
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 3650 -keyout "$CERT_DIR/tuic-key.pem" -out "$CERT_DIR/tuic-cert.pem" -subj "/CN=${SNI}"

  # 配置文件
  cat > "$CERT_DIR/config.json" <<EOF
{
  "server": "[::]:${PORT}",
  "users": { "auto": "${PASS}" },
  "certificate": "${CERT_DIR}/tuic-cert.pem",
  "private_key": "${CERT_DIR}/tuic-key.pem",
  "alpn": ["${ALPN}"],
  "congestion_control": "bbr",
  "disable_sni": false,
  "log_level": "warn"
}
EOF

  # systemd
  cat > "$CERT_DIR/tuicd.service" <<EOF
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

  sudo mv "$CERT_DIR/tuicd.service" /etc/systemd/system/tuicd.service
  sudo systemctl daemon-reload
  sudo systemctl enable tuicd
  sudo systemctl restart tuicd

  echo "✅ TUIC 已部署并启动"
  echo "节点链接: tuic://${PASS}@${IP}:${PORT}?sni=${SNI}&alpn=${ALPN}&insecure=true#TUIC"
}

uninstall_tuic() {
  echo "🗑 卸载 TUIC ..."
  sudo systemctl stop tuicd 2>/dev/null || true
  sudo systemctl disable tuicd 2>/dev/null || true
  rm -rf "$CERT_DIR"
  rm -f "$BIN"
  sudo rm -f /etc/systemd/system/tuicd.service
  sudo systemctl daemon-reload
  echo "✅ TUIC 卸载完成"
}

case "$MODE" in
  uninstall) uninstall_tuic ;;
  deploy) deploy_tuic ;;
  *) echo "❌ 模式错误，可选 deploy / uninstall"; exit 1 ;;
esac


