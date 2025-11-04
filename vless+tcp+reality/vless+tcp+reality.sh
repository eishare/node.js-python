#!/bin/bash
# =========================================
# VLESS + WS + TLS（强制使用 443 端口）
# 翼龙面板专用：必须开放 443 端口
# 完全忽略 3250，客户端链接使用 443
# 零依赖，无 jq，证书自动生成
# =========================================
set -uo pipefail

# ========== 强制使用 443 端口（TLS 必须）==========
PORT=443
echo "Using port: $PORT (TLS requires 443)"

# ========== 获取服务器 IP ==========
IP=$(curl -s https://api64.ipify.org || echo "127.0.0.1")
echo "Server IP: $IP"

# ========== 文件定义 ==========
WS_PATH="/$(openssl rand -hex 8)"
VLESS_BIN="./xray"
VLESS_CONFIG="vless-ws-tls.json"
VLESS_LINK="vless_link.txt"

# 证书目录（容器可写）
CERT_DIR="./certs"
CERT_PEM="$CERT_DIR/fullchain.pem"
KEY_PEM="$CERT_DIR/privkey.pem"

# ========== 生成证书目录 + 自签证书 ==========
gen_cert() {
  mkdir -p "$CERT_DIR"
  if [[ ! -f "$CERT_PEM" || ! -f "$KEY_PEM" ]]; then
    echo "Generating self-signed certificate for $IP..."
    openssl req -x509 -newkey rsa:2048 -keyout "$KEY_PEM" -out "$CERT_PEM" \
      -days 365 -nodes -subj "/CN=$IP" >/dev/null 2>&1
    chmod 644 "$CERT_PEM" "$KEY_PEM"
  fi
}

# ========== 下载 Xray ==========
get_xray() {
  if [[ ! -x "$VLESS_BIN" ]]; then
    echo "Downloading Xray v1.8.23..."
    curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/download/v1.8.23/Xray-linux-64.zip" --fail --connect-timeout 15
    unzip -j xray.zip xray -d . >/dev/null 2>&1
    rm -f xray.zip
    chmod +x "$VLESS_BIN"
  fi
}

# ========== URL 编码路径（无 jq）==========
url_encode() {
  local string="$1"
  printf '%s' "$string" | sed \
    -e 's/%/%25/g' \
    -e 's/ /%20/g' \
    -e 's/!/%21/g' \
    -e 's/"/%22/g' \
    -e 's/#/%23/g' \
    -e 's/\$/%24/g' \
    -e 's/&/%26/g' \
    -e "s/'/%27/g" \
    -e 's/(/%28/g' \
    -e 's/)/%29/g' \
    -e 's/\[/%5B/g' \
    -e 's/\]/%5D/g'
}

# ========== 生成配置（监听 443）==========
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

# ========== 生成客户端链接（使用 443）==========
gen_link() {
  local encoded_path=$(url_encode "$WS_PATH")
  cat > "$VLESS_LINK" <<EOF
vless://$VLESS_UUID@$IP:$PORT?encryption=none&security=tls&type=ws&host=$IP&path=$encoded_path#VLESS-WS-443
EOF

  echo "========================================="
  echo "VLESS + WS + TLS 部署成功！"
  echo "端口: $PORT"
  echo "IP: $IP"
  echo "WS Path: $WS_PATH"
  echo ""
  echo "客户端链接："
  cat "$VLESS_LINK"
  echo ""
  echo "翼龙面板设置："
  echo "  端口: 443 (TCP)"
  echo "  启动命令: ./deploy.sh"
  echo "========================================="
}

# ========== 启动 ==========
run_vless() {
  echo "Starting Xray on :$PORT..."
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
  gen_cert
  gen_config
  gen_link
  run_vless
}

main
