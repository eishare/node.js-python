#!/bin/bash
# ============================================================
# 一键部署 VLESS(WS+TLS,443) + TUIC 双协议节点
# 适配: Alpine / Debian / Ubuntu / CentOS / 非root环境
# 作者: eishare (2025)
# ============================================================

set -e
MASQ_DOMAIN="www.bing.com"
LOG_FILE="deploy.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "🚀 VLESS + TUIC 一键部署启动..."
echo "📜 日志保存到: $LOG_FILE"

# ============================================================
# 检查并安装依赖
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

TUIC_BIN="./tuic-server"
if [[ ! -x "$TUIC_BIN" ]]; then
  echo "📥 下载 tuic-server..."
  curl -L -o "$TUIC_BIN" https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-x86_64-linux
  chmod +x "$TUIC_BIN"
fi

CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
if [[ ! -f "$CERT_PEM" ]]; then
  echo "🔐 生成 TUIC 自签证书..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
fi

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
# VLESS + WS + TLS 配置
# ============================================================
XRAY_DIR="./xray"
mkdir -p "$XRAY_DIR"
cd "$XRAY_DIR"

XRAY_BIN="./xray"
if [[ ! -x "$XRAY_BIN" ]]; then
  echo "📥 下载 Xray 核心..."
  curl -L -o xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
  unzip -o xray.zip >/dev/null 2>&1
  chmod +x "$XRAY_BIN"
  rm -f xray.zip
fi

CERT_PEM="vless-cert.pem"
KEY_PEM="vless-key.pem"
if [[ ! -f "$CERT_PEM" ]]; then
  echo "🔐 生成 VLESS 自签证书..."
  openssl req -x509 -newkey rsa:2048 -keyout "$KEY_PEM" -out "$CERT_PEM" -days 365 \
    -subj "/CN=${MASQ_DOMAIN}" -nodes >/dev/null 2>&1
fi

UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)

cat > config.json <<EOF
{
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${UUID}" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${MASQ_DOMAIN}",
          "certificates": [
            {
              "certificateFile": "${CERT_PEM}",
              "keyFile": "${KEY_PEM}"
            }
          ]
        },
        "wsSettings": { "path": "/vless" }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

VLESS_IP=$(curl -s https://api.ipify.org || echo "your_server_ip")

cat > vless_link.txt <<EOF
vless://${UUID}@${VLESS_IP}:443?encryption=none&security=tls&type=ws&host=${MASQ_DOMAIN}&path=/vless#VLESS-${VLESS_IP}
EOF

echo "✅ VLESS 配置完成"
echo "🔗 VLESS 链接: $(cat vless_link.txt)"
cd ..

# ============================================================
# 启动后台服务
# ============================================================
echo "🚀 启动 TUIC 与 VLESS 服务..."

nohup ./tuic/tuic-server -c ./tuic/server.toml >/dev/null 2>&1 &
nohup ./xray/xray -c ./xray/config.json >/dev/null 2>&1 &

echo ""
echo "✅ 所有服务已启动"
echo "📄 TUIC 配置: $(pwd)/tuic/server.toml"
echo "📄 VLESS 配置: $(pwd)/xray/config.json"
echo "🪄 TUIC 链接: $(pwd)/tuic/tuic_link.txt"
echo "🪄 VLESS 链接: $(pwd)/xray/vless_link.txt"
echo "📜 日志文件: $LOG_FILE"
echo ""
echo "🎉 部署完成！"
