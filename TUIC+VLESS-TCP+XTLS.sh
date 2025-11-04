#!/bin/bash
set -e

# ====== 基础设置 ======
DOMAIN=www.bing.com
UUID=$(cat /proc/sys/kernel/random/uuid)
XRAY_VER="v1.8.8"

# ====== 安装依赖 ======
apt update -y >/dev/null 2>&1 || true
apt install -y wget unzip openssl >/dev/null 2>&1 || true

# ====== 生成自签名证书 ======
mkdir -p /root/certs
echo "🔐 Generating self-signed certificate for ${DOMAIN}..."
openssl req -x509 -newkey rsa:2048 -keyout /root/certs/private.key -out /root/certs/cert.pem -days 3650 -nodes -subj "/CN=${DOMAIN}" >/dev/null 2>&1

# ====== 下载 Xray-core ======
echo "📥 Downloading Xray-core (Lite)..."
wget -qO xray.zip "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-64.zip"
unzip -q xray.zip
chmod +x xray

# ====== 生成配置文件 ======
cat > /root/xray.json <<EOF
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
          "certificateFile": "/root/certs/cert.pem",
          "keyFile": "/root/certs/private.key"
        }]
      }
    }
  }],
  "outbounds": [{
    "protocol": "freedom"
  }]
}
EOF

# ====== 获取 IP 并生成节点链接 ======
SERVER_IP=$(curl -s ipv4.ip.sb || curl -s ipinfo.io/ip)
VLESS_LINK="vless://${UUID}@${SERVER_IP}:443?security=xtls&encryption=none&flow=xtls-rprx-vision&tls=xtls&sni=${DOMAIN}#VLESS-${SERVER_IP}"

# ====== 启动服务 ======
echo "✅ VLESS TCP+XTLS 已启动，端口: 443"
echo "🔗 节点链接:"
echo "${VLESS_LINK}"
echo ""
./xray run -c /root/xray.json
