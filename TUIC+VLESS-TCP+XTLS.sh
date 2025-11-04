#!/bin/bash
set -e

echo "✅ Using environment port: ${PORT:-$(shuf -i 1000-9999 -n 1)}"
PORT=${PORT:-$(shuf -i 1000-9999 -n 1)}
TUIC_PORT=$PORT
DOMAIN=www.bing.com

# 临时工作目录
WORKDIR=$(mktemp -d)
cd $WORKDIR

# ========= 安装依赖 =========
apt update -y >/dev/null 2>&1 || true
apt install -y wget curl unzip jq openssl >/dev/null 2>&1 || true

# ========= 生成证书 =========
echo "🔐 Generating self-signed certificate for $DOMAIN..."
mkdir -p /root/certs
openssl req -x509 -newkey rsa:2048 -keyout /root/certs/private.key -out /root/certs/cert.pem -days 3650 -nodes -subj "/CN=$DOMAIN" >/dev/null 2>&1

# ========= 生成随机UUID/密码 =========
UUID=$(cat /proc/sys/kernel/random/uuid)
TUIC_UUID=$(cat /proc/sys/kernel/random/uuid)
TUIC_PASS=$(openssl rand -hex 16)

# ========= 下载 TUIC =========
echo "📥 Downloading tuic-server..."
wget -qO tuic-server https://github.com/Itsusinn/tuic/releases/download/v1.4.5/tuic-server-x86_64-linux
chmod +x tuic-server

# ========= 下载 Xray =========
echo "📥 Downloading Xray-core (Lite)..."
wget -qO xray.zip https://github.com/XTLS/Xray-core/releases/download/v1.8.8/Xray-linux-64.zip
unzip -q xray.zip
chmod +x xray

# ========= TUIC 配置 =========
cat > tuic.json <<EOF
{
  "server": {
    "ip": "::",
    "port": $TUIC_PORT,
    "certificate": "/root/certs/cert.pem",
    "private_key": "/root/certs/private.key",
    "congestion_control": "bbr"
  },
  "users": {
    "$TUIC_UUID": "$TUIC_PASS"
  },
  "alpn": ["h3"],
  "log_level": "warn"
}
EOF

# ========= VLESS 配置 =========
cat > xray.json <<EOF
{
  "inbounds": [{
    "port": 443,
    "listen": "127.0.0.1",
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$UUID"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "xtls",
      "xtlsSettings": {
        "serverName": "$DOMAIN",
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

# ========= 生成分享链接 =========
SERVER_IP=$(curl -s ipv4.ip.sb || curl -s ipinfo.io/ip)
VLESS_LINK="vless://${UUID}@${SERVER_IP}:443?security=xtls&encryption=none&flow=xtls-rprx-vision&tls=xtls&sni=${DOMAIN}#VLESS-${SERVER_IP}"
TUIC_LINK="tuic://${TUIC_UUID}:${TUIC_PASS}@${SERVER_IP}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${SERVER_IP}"

# ========= 启动服务 =========
echo "✅ VLESS TCP+XTLS 已启动 (127.0.0.1:443)"
echo "🔗 VLESS Link:"
echo "$VLESS_LINK"
echo ""
echo "🔗 TUIC Link:"
echo "$TUIC_LINK"
echo ""
echo "🚀 Starting TUIC & VLESS in background..."

# 后台同时启动
./xray run -c xray.json >/dev/null 2>&1 &
./tuic-server -c tuic.json >/dev/null 2>&1 &

# 保持容器活跃
echo "✅ All services running. Press Ctrl+C to exit."
tail -f /dev/null
