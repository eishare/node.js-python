#!/bin/bash
set -euo pipefail
export LC_ALL=C
IFS=$'\n\t'

########################
# ===== 配置项 =====
########################
MASQ_DOMAIN="www.bing.com"
TUIC_VERSION="v1.4.5"

TUIC_BIN="./tuic-server"
TUIC_TOML="./server.toml"
TUIC_CERT="./tuic-cert.pem"
TUIC_KEY="./tuic-key.pem"
TUIC_LINK="./tuic_link.txt"

XRAY_BIN="./Xray-linux-64"       # 更新为 Xray-linux-64
XRAY_CONF="./xray.json"
REALITY_KEY_FILE="./reality_key.txt"
VLESS_INFO="./vless_reality_info.txt"

########################
# ===== 通用函数 =====
########################
gen_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
    return
  fi
  openssl rand -hex 16 | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/'
}

########################
# ===== TUIC 部分 =====
########################
random_port() { echo $(( (RANDOM % 40000) + 20000 )); }

read_tuic_port() {
  if [[ -n "${SERVER_PORT:-}" ]]; then
    TUIC_PORT="$SERVER_PORT"
  else
    TUIC_PORT=$(random_port)
  fi
  echo "✅ TUIC 使用端口: $TUIC_PORT"
}

generate_tuic_cert() {
  if [[ ! -f "$TUIC_CERT" || ! -f "$TUIC_KEY" ]]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "$TUIC_KEY" -out "$TUIC_CERT" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
    chmod 600 "$TUIC_KEY"
    chmod 644 "$TUIC_CERT"
  fi
}

check_tuic() {
  if [[ ! -x "$TUIC_BIN" ]]; then
    echo "📥 下载 TUIC..."
    curl -L -o "$TUIC_BIN" "https://github.com/Itsusinn/tuic/releases/download/${TUIC_VERSION}/tuic-server-x86_64-linux"
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
EOF
}

generate_tuic_link() {
  local ip="$1"
cat > "$TUIC_LINK" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native#TUIC-${ip}
EOF
  echo "🔗 TUIC 链接:"
  cat "$TUIC_LINK"
}

run_tuic() {
  nohup "$TUIC_BIN" -c "$TUIC_TOML" >/dev/null 2>&1 &
}

########################
# ===== VLESS Reality =====
########################
check_xray() {
  if [[ ! -x "$XRAY_BIN" ]]; then
    echo "❌ Xray 二进制文件不存在，请手动上传 Linux 64bit 可执行文件至 $XRAY_BIN"
    exit 1
  fi

  if command -v file >/dev/null 2>&1; then
    if ! file "$XRAY_BIN" | grep -qi ELF; then
      echo "❌ Xray 不是 ELF 可执行文件，请检查上传的 Xray-linux-64 是否正确"
      exit 1
    fi
  fi
}

generate_reality_keys() {
  "$XRAY_BIN" x25519 > "$REALITY_KEY_FILE" 2>/dev/null
  PRIVATE_KEY=$(grep -i "Private key" "$REALITY_KEY_FILE" | awk -F': ' '{print $2}' | tr -d '\r\n')
  PUBLIC_KEY=$(grep -i "Public key" "$REALITY_KEY_FILE" | awk -F': ' '{print $2}' | tr -d '\r\n')
  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    echo "❌ Reality 密钥生成失败，请检查 $XRAY_BIN 是否支持 x25519"
    exit 1
  fi
}

generate_vless_config() {
cat > "$XRAY_CONF" <<EOF
{
  "log": {"loglevel": "warning"},
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
  local server_ip
  server_ip=$(curl -s https://api64.ipify.org || echo "127.0.0.1")
cat > "$VLESS_INFO" <<EOF
VLESS Reality 节点信息
========================
UUID: ${VLESS_UUID}
PrivateKey: ${PRIVATE_KEY}
PublicKey: ${PUBLIC_KEY}
SNI: ${MASQ_DOMAIN}
Port: 443
Link:
vless://${VLESS_UUID}@${server_ip}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${MASQ_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}#VLESS-REALITY
========================
EOF
  cat "$VLESS_INFO"
}

run_vless() {
  nohup "$XRAY_BIN" run -c "$XRAY_CONF" >/dev/null 2>&1 &
}

########################
# ===== 主流程 =====
########################
main() {
  read_tuic_port
  TUIC_UUID=$(gen_uuid)
  VLESS_UUID=$(gen_uuid)
  TUIC_PASSWORD=$(openssl rand -hex 16)

  generate_tuic_cert
  check_tuic
  generate_tuic_config
  IP=$(curl -s https://api64.ipify.org || echo "127.0.0.1")
  generate_tuic_link "$IP"

  check_xray
  generate_reality_keys
  generate_vless_config
  generate_vless_link

  run_vless
  run_tuic

  echo "🎉 部署完成！"
  echo "TUIC 链接：$TUIC_LINK"
  echo "VLESS Reality 信息：$VLESS_INFO"
}

main "$@"
