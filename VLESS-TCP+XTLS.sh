#!/bin/bash
set -e

# ===== 基本配置 =====
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
  openssl req -x509 -newkey rsa:2048 -keyout "$CERT_DIR/private.key" -out "$CERT_DIR/cert.pem" \
    -days 365 -nodes -subj "/CN=${DOMAIN}" >/dev/null 2>&1
fi

# ===== 下载 Xray-core v25.10.15 =====
if [ ! -x "$XRAY_BIN" ]; then
  echo "📥 下载 Xray-core v${XRAY_VER}..."
  # 使用 GHProxy 镜像，避免 Pterodactyl 下载卡死
  curl -L -o xray.tgz "https://ghproxy.net/https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/Xray-linux-64.zip"
  
  # 解压
  if command -v unzip >/dev/null 2>&1; then
    unzip -q xray.tgz xray
  else
    echo "❌ 容器缺少 unzip，请先上传 Xray 或安装 unzip"
    exit 1
  fi
  
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

# ===== 获取公网 IP 并生成 VLESS 链接 =====
SERVER_IP=$(curl -s https://api64.ipify.org || echo "127.0.0.1")
VLESS_LINK="vless://${UUID}@${SERVER_IP}:443?security=xtls&encryption=none&flow=xtls-rprx-vision&tls=xtls&sni=${DOMAIN}#VLESS-${SERVER_IP}"

echo "✅ VLESS TCP+XTLS 已部署"
echo "🔗 节点链接:"
echo "$VLESS_LINK"
echo ""

# ===== 启动 Xray =====
exec "$XRAY_BIN" run -c "$CONF"
