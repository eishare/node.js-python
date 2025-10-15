#!/bin/bash
# ============================================================
# 一键部署 Argo(VLESS+WS+TLS) + TUIC 节点 (兼容非root)
# 适配: Alpine / Debian / Ubuntu / CentOS
# 作者: eishare (2025)
# ============================================================

set -e
MASQ_DOMAIN="www.bing.com"
LOG_FILE="deploy.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "🚀 Argo + TUIC 一键部署启动..."
echo "📜 日志保存到: $LOG_FILE"

# ============================================================
# 检查并安装依赖（兼容非root）
# ============================================================
install_base() {
  echo "📦 检查系统环境..."
  if command -v apt >/dev/null 2>&1; then
    PKG="apt"
  elif command -v yum >/dev/null 2>&1; then
    PKG="yum"
  elif command -v apk >/dev/null 2>&1; then
    PKG="apk"
  else
    echo "❌ 未检测到受支持的包管理器，请手动安装 curl unzip openssl"
    return
  fi

  for cmd in curl unzip openssl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "📥 安装依赖: $cmd"
      case $PKG in
        apt)  sudo apt update -y && sudo apt install -y "$cmd" ;;
        yum)  sudo yum install -y "$cmd" ;;
        apk)  sudo apk add --no-cache "$cmd" ;;
      esac
    fi
  done
}

install_base

# ============================================================
# TUIC 配置
# ============================================================
TUIC_PORT="${1:-}"
TUIC_DIR="./tuic"
mkdir -p "$TUIC_DIR"
cd "$TUIC_DIR"

if [[ -z "$TUIC_PORT" ]]; then
  read -rp "请输入 TUIC 端口 (1024-65535): " TUIC_PORT
fi

if ! [[ "$TUIC_PORT" =~ ^[0-9]+$ ]]; then
  echo "❌ 无效端口"
  exit 1
fi

echo "✅ TUIC 端口: $TUIC_PORT"

# -------------------- 下载 tuic-server --------------------
TUIC_BIN="./tuic-server"
if [[ ! -x "$TUIC_BIN" ]]; then
  echo "📥 下载 tuic-server..."
  curl -L -o "$TUIC_BIN" https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-x86_64-linux
  chmod +x "$TUIC_BIN"
fi

# -------------------- 生成证书 --------------------
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
if [[ ! -f "$CERT_PEM" ]]; then
  echo "🔐 生成自签证书..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
fi

# -------------------- TUIC 配置文件 --------------------
TUIC_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
TUIC_PASS=$(openssl rand -hex 8)

cat > server.toml <<EOF
log_level = "off"
server = "0.0.0.0:${TUIC_PORT}"

[users]
${TUIC_UUID} = "${TUIC_PASS}"

[tls]
certificate = "${CERT_PEM}"
private_key = "${KEY_PEM}"
alpn = ["h3"]
EOF

TUIC_IP=$(curl -s https://api.ipify.org || echo "your_server_ip")

cat > tuic_link.txt <<EOF
tuic://${TUIC_UUID}:${TUIC_PASS}@${TUIC_IP}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}#TUIC-${TUIC_IP}
EOF

echo "✅ TUIC 配置完成"
echo "🔗 TUIC 链接: $(cat tuic_link.txt)"
cd ..

# ============================================================
# Argo + VLESS 配置
# ============================================================
XRAY_DIR="./xray"
mkdir -p "$XRAY_DIR"
cd "$XRAY_DIR"

# -------------------- 下载 Xray --------------------
XRAY_BIN="./xray"
if [[ ! -x "$XRAY_BIN" ]]; then
  echo "📥 下载 Xray 核心..."
  curl -L -o xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
  unzip -o xray.zip >/dev/null 2>&1
  chmod +x "$XRAY_BIN"
  rm -f xray.zip
fi

# -------------------- VLESS 配置 --------------------
UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)

cat > config.json <<EOF
{
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": { "clients": [{ "id": "${UUID}" }], "decryption": "none" },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": { "serverName": "${MASQ_DOMAIN}", "allowInsecure": true },
        "wsSettings": { "path": "/argo" }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# -------------------- 下载 Argo --------------------
ARGO_BIN="./cloudflared"
if [[ ! -x "$ARGO_BIN" ]]; then
  echo "📥 下载 Cloudflare Argo Tunnel..."
  curl -L -o "$ARGO_BIN" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
  chmod +x "$ARGO_BIN"
fi

# -------------------- 启动 Argo 临时隧道 --------------------
echo "🌐 启动临时 Argo 隧道..."
$ARGO_BIN tunnel --url localhost:443 > argo.log 2>&1 &
sleep 8

TUNNEL_URL=$(grep -Eo 'https://[-0-9a-zA-Z]+\.trycloudflare\.com' argo.log | head -n 1)

if [[ -z "$TUNNEL_URL" ]]; then
  echo "❌ 未能获取 Argo 隧道地址，请稍后查看 argo.log"
else
  echo "✅ 临时隧道地址: $TUNNEL_URL"
fi

cat > vless_link.txt <<EOF
vless://${UUID}@${TUNNEL_URL#https://}:443?encryption=none&security=tls&type=ws&host=${MASQ_DOMAIN}&path=/argo#Argo-${MASQ_DOMAIN}
EOF

echo "✅ Argo + VLESS 已配置完成"
echo "🔗 VLESS 链接: $(cat vless_link.txt)"
cd ..

# ============================================================
# 启动后台服务
# ============================================================
echo "🚀 启动 TUIC 与 Xray 服务..."

nohup ./tuic/tuic-server -c ./tuic/server.toml >/dev/null 2>&1 &
nohup ./xray/xray -c ./xray/config.json >/dev/null 2>&1 &
nohup ./xray/cloudflared tunnel --url localhost:443 >/dev/null 2>&1 &

echo ""
echo "✅ 所有服务已启动"
echo "📄 TUIC 配置: $(pwd)/tuic/server.toml"
echo "📄 VLESS 配置: $(pwd)/xray/config.json"
echo "🪄 TUIC 链接: $(pwd)/tuic/tuic_link.txt"
echo "🪄 VLESS 链接: $(pwd)/xray/vless_link.txt"
echo "📜 日志文件: $LOG_FILE"
echo ""
echo "🎉 部署完成！"
