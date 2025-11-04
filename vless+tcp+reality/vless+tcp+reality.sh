#!/bin/bash
# =========================================
# 纯 VLESS + WS + TLS 单节点（支持 CDN）
# 翼龙面板专用：自动检测端口
# 晚高峰加速、Cloudflare CDN 完美兼容
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
  PORT=443  # CDN 推荐 443
  echo "Port (default): $PORT"
fi

# ========== 文件定义 ==========
DOMAIN="${DOMAIN:-vless-cdn.yourdomain.com}"  # 可环境变量覆盖
WS_PATH="/$(openssl rand -hex 8)"             # 随机路径防探测
VLESS_BIN="./xray"
VLESS_CONFIG="vless-ws-tls.json"
VLESS_LINK="vless_link.txt"
CERT_PEM="fullchain.pem"
KEY_PEM="privkey.pem"

# ========== 加载已有配置 ==========
load_config() {
  if [[ -f "$VLESS_CONFIG" ]]; then
    VLESS_UUID=$(grep -o '"id": "[^"]*' "$VLESS_CONFIG" | head -1 | cut -d'"' -f4)
    WS_PATH=$(grep -o '/[a-f0-9]\{16\}' "$VLESS_CONFIG" || echo "$WS_PATH")
    echo "Loaded existing UUID: $VLESS_UUID"
    echo "WS Path: $WS_PATH"
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

# ========== 生成自签证书（CDN 可用）==========
gen_cert() {
  if [[ ! -f "$CERT_PEM" || ! -f "$KEY_PEM" ]]; then
    echo "Generating self-signed TLS cert for $DOMAIN..."
    openssl req -x509 -newkey rsa:2048 -keyout "$KEY_PEM" -out "$CERT_PEM" \
      -days 365 -nodes -subj "/CN=$DOMAIN" >/dev/null 2>&1
  fi
}

# ========== 生成 VLESS-WS-TLS 配置 ==========
gen_vless_config() {
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
        "headers": {
          "Host": "$DOMAIN"
        }
      }
    },
    "sniffing": {
      "enabled": true,
      "destOverride": ["http", "tls"]
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

  # 保存信息
  cat > ws_info.txt <<EOF
Domain: $DOMAIN
WS Path: $WS_PATH
VLESS UUID: $VLESS_UUID
Port: $PORT
EOF
}

# ========== 生成客户端链接 ==========
gen_link() {
  local ip="$1"
  cat > "$VLESS_LINK" <<EOF
vless://$VLESS_UUID@$DOMAIN:$PORT?encryption=none&security=tls&type=ws&host=$DOMAIN&path=$(printf '%s' "$WS_PATH" | jq -Rr @uri)#VLESS-WS-CDN
EOF

  echo "========================================="
  echo "VLESS + WS + TLS Node (CDN Ready):"
  echo "Domain: $DOMAIN"
  echo "Port: $PORT"
  echo "WS Path: $WS_PATH"
  cat "$VLESS_LINK"
  echo "========================================="
}

# ========== 启动服务 ==========
run_vless() {
  echo "Starting VLESS-WS-TLS on :$PORT (CDN Mode)..."
  while true; do
    "$VLESS_BIN" run -c "$VLESS_CONFIG" >/dev/null 2>&1 || sleep 5
  done
}

# ========== 主函数 ==========
main() {
  echo "Deploying VLESS + WS + TLS (CDN Optimized)"

  load_config
  [[ -z "${VLESS_UUID:-}" ]] && VLESS_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)

  get_xray
  gen_cert
  gen_vless_config

  ip=$(curl -s https://api64.ipify.org || echo "127.0.0.1")
  gen_link "$ip"

  echo "=== Cloudflare CDN 设置 ==="
  echo "1. 添加 A 记录: $DOMAIN → $ip"
  echo "2. 开启代理（橙色云）"
  echo "3. SSL/TLS → Full (strict)"
  echo "============================"

  run_vless
}

main "$@"
