#!/bin/bash
set -euo pipefail
export LC_ALL=C
IFS=$'\n\t'

# ===== 配置 =====
DOMAIN="www.bing.com"
UUID=$(cat /proc/sys/kernel/random/uuid)
XRAY_VER="v25.10.15"
XRAY_BIN="./xray"
CERT_DIR="./certs"
CONF="./xray.json"

mkdir -p "$CERT_DIR"

# ===== 生成自签证书 =====
if [ ! -f "$CERT_DIR/cert.pem" ]; then
  echo "🔐 生成自签名证书 (${DOMAIN})..."
  openssl req -x509 -newkey rsa:2048 \
    -keyout "$CERT_DIR/private.key" \
    -out "$CERT_DIR/cert.pem" \
    -days 365 -nodes -subj "/CN=${DOMAIN}" >/dev/null 2>&1
fi

# ===== 下载 Xray-core tar.gz =====
if [ ! -x "$XRAY_BIN" ]; then
  echo "📥 下载 Xray-core v${XRAY_VER} (tar.gz)..."
  curl -L -o xray.tgz "https://ghproxy.net/https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/Xray-linux-64.tar.gz"
  
  if [ ! -s xray.tgz ]; then
    echo "❌ 下载失败，请检查网络或镜像源"
    exit 1
  fi

  tar -xzf xray.tgz xray >/dev/null 2>&1 || { echo "❌ 解压失败"; exit 1; }
  chmod +x xray
  rm -f xray.tgz
fi

# ===== 生成 VLESS+TCP+XTLS 配置 =====
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

# ===== 输出 VLESS 链接 =====
SERVER_IP=$(curl -s https://api64.ipify.org || echo "127.0.0.1")
VLESS_LINK="vless://${UUID}@${SERVER_IP}:443?security=xtls&encryption=none&flow=xtls-rprx-vision&tls=xtls&sni=${DOMAIN}#VLESS-${SERVER_IP}"

echo "✅ VLESS TCP+XTLS 已部署"
echo "🔗 节点链接:"
echo "$VLESS_LINK"
echo ""

# ===== 启动 Xray =====
exec "$XRAY_BIN" run -c "$CONF"
