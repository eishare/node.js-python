#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# 默认端口范围
START_PORT=${1:-20000}
END_PORT=${2:-20010}

# 随机选端口
SERVER_PORT=$(shuf -i $START_PORT-$END_PORT -n 1)

PASSWORD="tuic_$(date +%s | md5sum | head -c 6)"
SNI="www.bing.com"
ALPN="h3"

# 安装依赖
if command -v apk &>/dev/null; then apk add --no-cache curl openssl coreutils >/dev/null; fi
if command -v apt &>/dev/null; then apt update && apt install -y curl openssl coreutils >/dev/null; fi
if command -v yum &>/dev/null; then yum install -y curl openssl coreutils >/dev/null; fi

# 获取公网 IP
IP=$(curl -s https://api.ipify.org || echo "YOUR_SERVER_IP")

# 下载 tuic-server
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then ARCH="x86_64"; fi
if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then ARCH="aarch64"; fi

BIN="/usr/local/bin/tuic-server"
if [[ ! -x "$BIN" ]]; then
  curl -L -o "$BIN" "https://github.com/EAimTY/tuic/releases/latest/download/tuic-server-${ARCH}-unknown-linux-musl"
  chmod +x "$BIN"
fi

# 生成证书
CERT_DIR="/etc/tuic"
mkdir -p "$CERT_DIR"
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -days 3650 -keyout "$CERT_DIR/tuic-key.pem" -out "$CERT_DIR/tuic-cert.pem" -subj "/CN=${SNI}"

# 生成配置文件
cat > "$CERT_DIR/config.json" <<EOF
{
  "server": "[::]:${SERVER_PORT}",
  "users": {
    "auto": "${PASSWORD}"
  },
  "certificate": "${CERT_DIR}/tuic-cert.pem",
  "private_key": "${CERT_DIR}/tuic-key.pem",
  "alpn": ["${ALPN}"],
  "congestion_control": "bbr",
  "disable_sni": false,
  "log_level": "warn"
}
EOF

# systemd 服务
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
echo "节点链接: tuic://${PASSWORD}@${IP}:${SERVER_PORT}?sni=${SNI}&alpn=${ALPN}&insecure=true#TUIC"

# 一键卸载
if [[ "${3:-}" == "uninstall" ]]; then
  systemctl stop tuicd
  systemctl disable tuicd
  rm -f /etc/systemd/system/tuicd.service
  rm -rf "$CERT_DIR"
  rm -f "$BIN"
  systemctl daemon-reload
  echo "🗑 TUIC 已卸载"
  exit 0
fi
