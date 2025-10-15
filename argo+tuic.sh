#!/bin/bash
# ============================================================
# 稳定版 VLESS(WS+TLS,443) + TUIC 双协议部署
# 修正版：固定公网IP + Xray 校验 + 非 root 环境
# ============================================================

set -e
MASQ_DOMAIN="www.bing.com"
LOG_FILE="deploy.log"
PUBLIC_IP="${PUBLIC_IP:-}"

# 日志输出
exec > >(tee -a "$LOG_FILE") 2>&1

echo "🚀 VLESS + TUIC 一键部署启动..."
echo "📜 日志保存到: $LOG_FILE"

# ============================================================
# 检查依赖
# ============================================================
check_deps() {
    for cmd in curl openssl; do
        if ! command -v $cmd >/dev/null 2>&1; then
            echo "❌ 缺少依赖: $cmd，请手动安装"
            exit 1
        fi
    done
}

check_deps

# ============================================================
# 获取公网 IP
# ============================================================
if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP=$(curl -s https://api.ipify.org || true)
fi

if [[ -z "$PUBLIC_IP" ]]; then
    echo "❌ 无法获取公网 IP，请设置环境变量 PUBLIC_IP"
    exit 1
fi

echo "✅ 公网 IP: $PUBLIC_IP"

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

cat > tuic_link.txt <<EOF
tuic://${TUIC_UUID}:${TUIC_PASS}@${PUBLIC_IP}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}#TUIC-${PUBLIC_IP}
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
    echo "📥 下载 Xray 可执行文件..."
    curl -L -o "$XRAY_BIN" https://github.com/XTLS/Xray-core/releases/latest/download/xray-linux-64
    if [[ ! -s "$XRAY_BIN" ]]; then
        echo "❌ Xray 下载失败或文件损坏"
        exit 1
    fi
    chmod +x "$XRAY_BIN"
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

cat > vless_link.txt <<EOF
vless://${UUID}@${PUBLIC_IP}:443?encryption=none&security=tls&type=ws&host=${MASQ_DOMAIN}&path=/vless#VLESS-${PUBLIC_IP}
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
