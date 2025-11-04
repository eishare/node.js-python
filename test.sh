#!/bin/bash
# =========================================
# 单节点：VLESS + TCP + Reality
# 翼龙面板专用：自动检测端口
# 零冲突、Reality 伪装、单端口
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
  PORT=3250
  echo "Port (default): $PORT"
fi

# ========== 文件定义 ==========
MASQ_DOMAIN="www.bing.com"
VLESS_BIN="./xray"
VLESS_CONFIG="vless-reality.json"
VLESS_LINK="vless_link.txt"

# ========== 加载配置 ==========
load_config() {
  [[ -f "$VLESS_CONFIG" ]] && {
    VLESS_UUID=$(grep -o '"id": "[^"]*' "$VLESS_CONFIG" | head -1 | cut -d'"' -f4)
  }
}

# ========== 下载 Xray ==========
get_xray() {
  [[ -x "$VLESS_BIN" ]] && return
  echo "Downloading Xray..."
  curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/download/v1.8.23/Xray-linux-64.zip" --fail --connect-timeout 15
  unzip -j xray.zip xray -d . >/dev/null 2>&1
  rm -f xray.zip
  chmod +x "$VLESS_BIN"
}

# ========== 生成 VLESS Reality 配置 ==========
gen_vless_config() {
  local shortId=$(openssl rand -hex 8)
  local keys=$("$VLESS_BIN" x25519 2>/dev/null || echo "Private key: fallbackpriv1234567890abcdef1234567890abcdef\nPublic key: fallbackpubk1234567890abcdef1234567890abcdef")
  local priv=$(echo "$keys" | grep Private | awk '{print $3}')
  local pub=$(echo "$keys" | grep Public | awk '{print $3}')

  cat > "$VLESS_CONFIG" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$VLESS_UUID", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$MASQ_DOMAIN:443",
        "xver": 0,
        "serverNames": ["$MASQ_DOMAIN", "www.microsoft.com"],
        "privateKey": "$priv",
        "publicKey": "$pub",
        "shortIds": ["$shortId"],
        "fingerprint": "chrome",
        "spiderX": "/"
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

  echo "Reality Public Key: $pub" > reality_info.txt
  echo "Reality Short ID: $shortId" >> reality_info.txt
  echo "VLESS UUID: $VLESS_UUID" >> reality_info.txt
  echo "Port: $PORT" >> reality_info.txt
}

# ========== 生成客户端链接 ==========
gen_link() {
  local ip="$1"
  local pub=$(grep "Public Key" reality_info.txt | awk '{print $4}')
  local sid=$(grep "Short ID" reality_info.txt | awk '{print $4}')

  printf "vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&spx=/#VLESS-Reality\n" \
    "$VLESS_UUID" "$ip" "$PORT" "$MASQ_DOMAIN" "$pub" "$sid" > "$VLESS_LINK"

  echo "========================================="
  echo "VLESS Reality Node:"
  cat "$VLESS_LINK"
  echo "========================================="
}

# ========== 启动服务 ==========
run_vless() {
  echo "Starting VLESS Reality on :$PORT..."
  while :; do
    "$VLESS_BIN" run -c "$VLESS_CONFIG" >/dev/null 2>&1 || sleep 5
  done
}

# ========== 主函数 ==========
main() {
  load_config
  [[ -z "${VLESS_UUID:-}" ]] && VLESS_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)

  get_xray
  gen_vless_config

  ip=$(curl -s https://api64.ipify.org || echo "127.0.0.1")
  gen_link "$ip"

  run_vless
}

main "$@"
