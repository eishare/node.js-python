#!/bin/bash
# =========================================
# VLESS + WS + TLS（强制监听 443）
# 翼龙面板：外部 3250 → 内部 443
# 客户端链接使用 IP + 3250
# 解决：端口错乱、-1 延迟
# =========================================
set -uo pipefail

# ========== 强制内部监听 443（CDN/TLS 必须）==========
INTERNAL_PORT=443
echo "Internal listening port: $INTERNAL_PORT"

# ========== 自动检测外部端口（翼龙 SERVER_PORT）==========
if [[ -n "${SERVER_PORT:-}" ]]; then
  EXTERNAL_PORT="$SERVER_PORT"
  echo "External port (env): $EXTERNAL_PORT"
elif [[ $# -ge 1 && -n "$1" ]]; then
  EXTERNAL_PORT="$1"
  echo "External port (arg): $EXTERNAL_PORT"
else
  EXTERNAL_PORT=3250
  echo "External port (default): $EXTERNAL_PORT"
fi

# ========== 获取服务器 IP ==========
IP=$(curl -s https://api64.ipify.org || echo "127.0.0.1")
echo "Server IP: $IP"

# ========== 文件定义 ==========
WS_PATH="/$(openssl rand -hex 8)"
VLESS_BIN="./xray"
VLESS_CONFIG="vless-ws-tls.json"
VLESS_LINK="vless_link.txt"

# 证书路径
CERT_DIR="/certs"
CERT_PEM="$CERT_DIR/fullchain.pem"
KEY_PEM="$CERT_DIR/privkey.pem"

# ========== 检查证书（必须真实证书）==========
check_cert() {
  if [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]]; then
    echo "Using certificate: $CERT_PEM"
  else
    echo "ERROR: 证书未找到！"
    echo "请上传 Let's Encrypt 证书到："
    echo "  $CERT_PEM"
    echo "  $KEY_PEM"
    echo "或运行："
    echo "certbot certonly --standalone -d yourdomain.com"
    exit 1
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

# ========== 生成配置（监听 443）==========
gen_config() {
  cat > "$VLESS_CONFIG" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": $INTERNAL_PORT,
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

# ========== 生成客户端链接（外部端口）==========
gen_link() {
  local encoded_path=$(printf '%s' "$WS_PATH" | jq -Rr @uri 2>/dev/null || printf '%s' "$WS_PATH")
  cat > "$VLESS_LINK" <<EOF
vless://$VLESS_UUID@$IP:$EXTERNAL_PORT?encryption=none&security=tls&type=ws&host=$IP&path=$encoded_path#VLESS-WS-3250
EOF

  echo "========================================="
  echo "VLESS + WS + TLS 部署成功！"
  echo "内部端口: $INTERNAL_PORT (TLS)"
  echo "外部端口: $EXTERNAL_PORT (翼龙映射)"
  echo "IP: $IP"
  echo "WS Path: $WS_PATH"
  echo ""
  echo "客户端链接："
  cat "$VLESS_LINK"
  echo ""
  echo "翼龙面板设置："
  echo "  端口: $EXTERNAL_PORT (TCP)"
  echo "  映射: $EXTERNAL_PORT → $INTERNAL_PORT"
  echo "========================================="
}

# ========== 启动 ==========
run_vless() {
  echo "Starting VLESS-WS-TLS on :$INTERNAL_PORT..."
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
