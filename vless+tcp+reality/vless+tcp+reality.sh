#!/bin/bash
# =========================================
# VLESS + WS + TLS + CDN 专用（晚高峰丝滑）
# 翼龙面板：固定 443 端口 + 自动证书 + CDN 直连
# 解决：端口非443、CDN -1
# =========================================
set -uo pipefail

# ========== 强制使用 443 端口（CDN 必备）==========
PORT=443
echo "Using fixed port for CDN: $PORT"

# ========== 域名（必须自定义，CDN 必填）==========
DOMAIN="${DOMAIN:-}"  # 必须通过环境变量传入
if [[ -z "$DOMAIN" ]]; then
  echo "ERROR: 必须设置 DOMAIN 环境变量！"
  echo "示例: DOMAIN=vless.yourdomain.com ./deploy.sh"
  exit 1
fi
echo "Domain: $DOMAIN"

# ========== 文件定义 ==========
WS_PATH="/$(openssl rand -hex 8)"
VLESS_BIN="./xray"
VLESS_CONFIG="vless-ws-tls.json"
VLESS_LINK="vless_link.txt"
CERT_PEM="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY_PEM="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

# ========== 检查证书（优先 Let's Encrypt）==========
check_cert() {
  if [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]]; then
    echo "Using existing Let's Encrypt cert: $DOMAIN"
    return 0
  else
    echo "Certificate not found! Please upload Let's Encrypt cert to:"
    echo "  $CERT_PEM"
    echo "  $KEY_PEM"
    echo "Or use self-signed (not recommended for CDN):"
    gen_self_signed_cert
  fi
}

# ========== 生成自签证书（备用）==========
gen_self_signed_cert() {
  echo "Generating self-signed cert for $DOMAIN..."
  mkdir -p /etc/letsencrypt/live/$DOMAIN
  openssl req -x509 -newkey rsa:2048 -keyout "$KEY_PEM" -out "$CERT_PEM" \
    -days 365 -nodes -subj "/CN=$DOMAIN" >/dev/null 2>&1
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
        "path": "$WS_PATH",
        "headers": {"Host": "$DOMAIN"}
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
}

# ========== 生成链接 ==========
gen_link() {
  cat > "$VLESS_LINK" <<EOF
vless://$VLESS_UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=$(printf '%s' "$WS_PATH" | jq -Rr @uri)#VLESS-WS-CDN
EOF

  echo "========================================="
  echo "VLESS + WS + TLS + CDN 节点已就绪！"
  echo "Domain: $DOMAIN"
  echo "Port: 443"
  echo "WS Path: $WS_PATH"
  echo ""
  echo "客户端链接："
  cat "$VLESS_LINK"
  echo ""
  echo "Cloudflare 设置："
  echo "1. A 记录: $DOMAIN → $(curl -s https://api64.ipify.org)"
  echo "2. 代理状态：开启（橙色云）"
  echo "3. SSL/TLS：Full (strict)"
  echo "========================================="
}

# ========== 启动 ==========
run_vless() {
  echo "Starting VLESS-WS-TLS on :443..."
  exec "$VLESS_BIN" run -c "$VLESS_CONFIG"
}

# ========== 主函数 ==========
main() {
  # 加载 UUID
  if [[ -f "$VLESS_CONFIG" ]]; then
    VLESS_UUID=$(grep -o '"id": "[^"]*' "$VLESS_CONFIG" | head -1 | cut -d'"' -f4)
    echo "Loaded UUID: $VLESS_UUID"
  else
    VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
    echo "Generated UUID: $VLESS_UUID"
  fi

  get_xray
  check_cert
  gen_config
  gen_link
  run_vless
}

main
