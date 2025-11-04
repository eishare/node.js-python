#!/bin/bash
# =========================================
# VLESS + WS + TLS（IP 直连 + CDN 兼容）
# 翼龙面板：自动匹配 SERVER_PORT
# 客户端链接使用 IP 地址
# 解决：端口非443、CDN -1
# =========================================
set -uo pipefail

# ========== 自动检测端口（翼龙环境变量优先）==========
if [[ -n "${SERVER_PORT:-}" ]]; then
  PORT="$SERVER_PORT"
  echo "Port (env): $PORT"
elif [[ $# -ge 1 && -n "$1" ]]; then
  PORT="$1"
  echo "Port (arg): $PORT"
else
  PORT=443
  echo "Port (default): $PORT"
fi

# ========== 获取服务器 IP ==========
IP=$(curl -s https://api64.ipify.org || echo "127.0.0.1")
echo "Server IP: $IP"

# ========== 文件定义 ==========
WS_PATH="/$(openssl rand -hex 8)"
VLESS_BIN="./xray"
VLESS_CONFIG="vless-ws-tls.json"
VLESS_LINK="vless_link.txt"

# 证书路径（支持自定义上传）
CERT_DIR="${CERT_DIR:-/certs}"
CERT_PEM="$CERT_DIR/fullchain.pem"
KEY_PEM="$CERT_DIR/privkey.pem"

# ========== 检查证书 ==========
check_cert() {
  if [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]]; then
    echo "Using certificate: $CERT_PEM"
    return 0
  else
    echo "Certificate not found! Generating self-signed..."
    mkdir -p "$CERT_DIR"
    openssl req -x509 -newkey rsa:2048 -keyout "$KEY_PEM" -out "$CERT_PEM" \
      -days 365 -nodes -subj "/CN=$IP" >/dev/null 2>&1
  fi
}

# ========== 下载 Xray ==========
get_xray() {
  if [[ ! -x "$VLESS_BIN" ]]; then
    echo "Downloading Xray..."
    curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/download/v1.8.23/Xray-linux-64.zip" --fail --connect-timeout 15
    unzip -j xray.zip xray -d . >/dev/null 2>&1
    rm -f xray.zip
    chmod +x "$VLESS_BIN"
  fi
}

# ========== 生成配置 ==========
gen_config() {
  cat > "$VLESS_CONFIG" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$VLESS_UUID"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "tlsSettings": {
        "certificates": [{
          "certificateFile": "$CERT_PEM",
          "keyFile": "$KEY_PEM"
        }],
        "alpn": ["http/1.1"]
      },
      "wsSettings": {
        "path": "$WS_PATH"
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
}

# ========== 生成客户端链接（使用 IP）==========
gen_link() {
  local encoded_path=$(printf '%s' "$WS_PATH" | jq -Rr @uri)
  cat > "$VLESS_LINK" <<EOF
vless://$VLESS_UUID@$IP:$PORT?encryption=none&security=tls&type=ws&host=$IP&path=$encoded_path#VLESS-WS-IP
EOF

  echo "========================================="
  echo "VLESS + WS + TLS 节点已就绪！"
  echo "IP: $IP"
  echo "Port: $PORT"
  echo "WS Path: $WS_PATH"
  echo ""
  echo "客户端链接（IP 直连）："
  cat "$VLESS_LINK"
  echo ""
  echo "CDN 模式（可选）："
  echo "1. Cloudflare 添加 A 记录: cdn.example.com → $IP"
  echo "2. 开启代理（橙色云）"
  echo "3. 客户端改 host=cdn.example.com"
  echo "========================================="
}

# ========== 启动 ==========
run_vless() {
  echo "Starting VLESS-WS-TLS on :$PORT..."
  exec "$VLESS_BIN" run -c "$VLESS_CONFIG"
}

# ========== 主函数 ==========
main() {
  # 加载或生成 UUID
  if [[ -f "$VLESS_CONFIG" ]]; then
    VLESS_UUID=$(grep -o '"id": "[^"]*' "$VLESS_CONFIG" | head -1 | cut -d'"' -f4)
    echo "Loaded UUID: $VLESS_UUID"
  else
    VLESS_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)
    echo "Generated UUID: $VLESS_UUID"
  fi

  get_xray
  check_cert
  gen_config
  gen_link
  run_vless
}

main
