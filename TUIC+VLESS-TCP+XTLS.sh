#!/bin/bash
set -e

# ===== 基本配置 =====
DOMAIN=www.bing.com
UUID=$(cat /proc/sys/kernel/random/uuid)
XRAY_VER="v1.8.8"
XRAY_BIN="./xray"
CERT_DIR="./certs"
CONF="./xray.json"

# ===== 生成自签证书 =====
mkdir -p "$CERT_DIR"
if [ ! -f "$CERT_DIR/cert.pem" ]; then
  echo "🔐 生成自签名证书 (${DOMAIN})..."
  openssl req -x509 -newkey rsa:1024 -keyout "$CERT_DIR/private.key" -out "$CERT_DIR/cert.pem" \
    -days 365 -nodes -subj "/CN=${DOMAIN}" >/dev/null 2>&1
fi

# ===== 下载 Xray-core (tar.gz 版本) =====
if [ ! -x "$XRAY_BIN" ]; then
  echo "📥 下载 Xray-core (Lite)..."
  curl -L -o xray.tgz "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-64.zip"
  # 自动检测是否存在 unzip 或 tar
  if command -v unzip >/dev/null 2>&1; then
    unzip -q xray.tgz xray
  elif command -v tar >/dev/null 2>&1; then
    tar -xzf xray.tgz xray 2>/dev/null || true
  else
    echo "❌ 环境缺少 unzip 或 tar，请安装其中之一"
    exit 1
  fi
  chmod +x xray
  rm -f xray.tgz
fi

# ===== 生成配置 =====
cat > "$CONF" <<EOF
{
  "inbounds": [{
    "port": 443,
    "listen": "0.0.0.0",
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${UUID}"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "xtls",
      "xtlsSettings": {
        "serverName": "${DOMAIN}",
        "alpn": ["http/1.1"],
        "certificates": [{
          "certificateFile": "${CERT_DIR}/cert.pem",
          "keyFile": "${CERT_DIR}/private.key"
        }]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

# ===== 获取 IP 并生成链接 =====
SERVER_IP=$(curl -s https://api64.ipify.org || echo "127.0.0.1")
VLESS_LINK="vless://${UUID}@${SERVER_IP}:443?security=xtls&encryption=none&flow=xtls-rprx-vision&tls=xtls&sni=${DOMAIN}#VLESS-${SERVER_IP}"

echo "✅ VLESS TCP+XTLS 已部署"
echo "🔗 节点链接:"
echo "$VLESS_LINK"
echo ""

# ===== 启动服务 =====
exec "$XRAY_BIN" run -c "$CONF"
