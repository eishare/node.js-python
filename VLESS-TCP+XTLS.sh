#!/bin/bash
# =========================================
# TUIC v1.4.5 + VLESS TCP+REALITY 自动部署脚本（Node.js / 容器适用）
# =========================================

set -euo pipefail
export LC_ALL=C
IFS=$'\n\t'

########################
# ===== 通用工具 =====
########################

MASQ_DOMAIN="www.bing.com"
XRAY_VER="v25.10.15"

# ---- UUID 兼容函数 ----
gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  else
    cat /proc/sys/kernel/random/uuid 2>/dev/null || \
    openssl rand -hex 16 | sed 's/\(..\)/\1/g; s/\(..\)/\1-/5; s/\(..\)/\1-/7; s/\(..\)/\1-/9; s/\(..\)/\1-/11'
  fi
}

# ---- 下载工具（自动镜像）----
fetch() {
  local url="$1"
  local output="$2"
  echo "📥 下载：$url"
  if ! curl -L --connect-timeout 10 -o "$output" "$url"; then
    echo "⚠️ 主源失败，尝试使用镜像..."
    curl -L -o "$output" "https://ghproxy.com/$url"
  fi
}

########################
# ===== TUIC 配置 =====
########################

MASQ_DOMAIN="www.bing.com"
TUIC_TOML="server.toml"
TUIC_CERT="tuic-cert.pem"
TUIC_KEY="tuic-key.pem"
TUIC_LINK="tuic_link.txt"
TUIC_BIN="./tuic-server"

random_port() { echo $(( (RANDOM % 40000) + 20000 )); }

read_tuic_port() {
  if [[ -n "${SERVER_PORT:-}" ]]; then
    TUIC_PORT="$SERVER_PORT"
    echo "✅ 使用环境端口: $TUIC_PORT"
  else
    TUIC_PORT=$(random_port)
    echo "🎲 TUIC 随机UDP端口: $TUIC_PORT"
  fi
}

generate_tuic_cert() {
  if [[ ! -f "$TUIC_CERT" || ! -f "$TUIC_KEY" ]]; then
    echo "🔐 生成 TUIC 自签证书..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "$TUIC_KEY" -out "$TUIC_CERT" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
    chmod 600 "$TUIC_KEY" && chmod 644 "$TUIC_CERT"
  fi
}

check_tuic() {
  if [[ ! -x "$TUIC_BIN" ]]; then
    echo "📥 下载 TUIC..."
    fetch "https://github.com/Itsusinn/tuic/releases/download/v1.4.5/tuic-server-x86_64-linux" "$TUIC_BIN"
    chmod +x "$TUIC_BIN"
  fi
}

generate_tuic_config() {
cat > "$TUIC_TOML" <<EOF
log_level = "warn"
server = "0.0.0.0:${TUIC_PORT}"
udp_relay_ipv6 = false
zero_rtt_handshake = true
dual_stack = false
auth_timeout = "8s"
gc_interval = "8s"
gc_lifetime = "8s"
max_external_packet_size = 8192

[users]
${TUIC_UUID} = "${TUIC_PASSWORD}"

[tls]
certificate = "$TUIC_CERT"
private_key = "$TUIC_KEY"
alpn = ["h3"]

[quic.congestion_control]
controller = "bbr"
EOF
}

generate_tuic_link() {
  local ip="$1"
  cat > "$TUIC_LINK" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0#TUIC-${ip}
EOF
  echo "🔗 TUIC 链接:"
  cat "$TUIC_LINK"
}

run_tuic() {
  echo "🚀 启动 TUIC..."
  nohup "$TUIC_BIN" -c "$TUIC_TOML" >/dev/null 2>&1 &
}

########################
# ===== VLESS REALITY =====
########################

XRAY_BIN="./xray"
XRAY_CONF="./xray.json"

check_xray() {
  if [[ ! -x "$XRAY_BIN" ]]; then
    echo "📥 下载 Xray-core ${XRAY_VER}..."
    fetch "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-64.zip" "xray.zip"
    unzip -o xray.zip >/dev/null 2>&1
    chmod +x xray
    mv xray "$XRAY_BIN"
  fi
}

generate_reality_keys() {
  echo "🔑 生成 Reality 密钥对..."
  if ! "$XRAY_BIN" x25519 > reality_key.txt 2>/dev/null; then
    echo "❌ Reality 密钥生成失败"
    exit 1
  fi
  PRIVATE_KEY=$(grep "Private" reality_key.txt | awk '{print $3}')
  PUBLIC_KEY=$(grep "Public" reality_key.txt | awk '{print $3}')
}

generate_vless_config() {
cat > "$XRAY_CONF" <<EOF
{
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${VLESS_UUID}", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${MASQ_DOMAIN}:443",
        "xver": 0,
        "serverNames": ["${MASQ_DOMAIN}"],
        "privateKey": "${PRIVATE_KEY}",
        "shortIds": [""]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
}

generate_vless_link() {
  SERVER_IP=$(curl -s https://api64.ipify.org || echo "127.0.0.1")
  VLESS_LINK="vless://${VLESS_UUID}@${SERVER_IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${MASQ_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&type=tcp#VLESS-REALITY-${SERVER_IP}"
  echo "🔗 VLESS Reality 链接:"
  echo "$VLESS_LINK"
}

run_vless() {
  echo "🚀 启动 VLESS Reality..."
  nohup "$XRAY_BIN" run -c "$XRAY_CONF" >/dev/null 2>&1 &
}

########################
# ===== 主流程 =====
########################
main() {
  # TUIC
  read_tuic_port
  TUIC_UUID=$(gen_uuid)
  TUIC_PASSWORD=$(openssl rand -hex 16)
  generate_tuic_cert
  check_tuic
  generate_tuic_config
  IP=$(curl -s https://api64.ipify.org || echo "127.0.0.1")
  generate_tuic_link "$IP"

  # VLESS Reality
  VLESS_UUID=$(gen_uuid)
  check_xray
  generate_reality_keys
  generate_vless_config
  generate_vless_link

  # 启动服务
  run_vless
  run_tuic
  wait
}

main "$@"
