#!/bin/bash
# =========================================
# TUIC v1.4.5 + VLESS Reality 自动部署脚本（Node.js 容器适用）
# 修正版：修复 Xray 下载路径 vv25.10.15 问题 + 增加检测
# =========================================

set -euo pipefail
export LC_ALL=C
IFS=$'\n\t'

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
    curl -L -s -o "$TUIC_BIN" "https://github.com/Itsusinn/tuic/releases/download/v1.4.5/tuic-server-x86_64-linux"
    chmod +x "$TUIC_BIN"
  fi
}

generate_tuic_config() {
cat > "$TUIC_TOML" <<EOF
log_level = "warn"
server = "0.0.0.0:${TUIC_PORT}"

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
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${ip}
EOF
  echo "🔗 TUIC 链接:"
  cat "$TUIC_LINK"
}

run_tuic() {
  echo "🚀 启动 TUIC..."
  while true; do
    "$TUIC_BIN" -c "$TUIC_TOML" >/dev/null 2>&1 || true
    echo "⚠️ TUIC 崩溃，5秒后重启..."
    sleep 5
  done
}

########################
# ===== VLESS Reality =====
########################
XRAY_VER="25.10.15"
XRAY_BIN="./xray"
XRAY_CONF="./xray.json"

check_xray() {
  if [[ ! -x "$XRAY_BIN" || ! -s "$XRAY_BIN" ]]; then
    echo "📥 下载 Xray-core v${XRAY_VER}..."
    curl -L -s -o "$XRAY_BIN" "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/Xray-linux-64" || true
    chmod +x "$XRAY_BIN" || true
  fi

  # 验证下载是否为可执行文件
  if ! file "$XRAY_BIN" | grep -q ELF; then
    echo "❌ 下载的 xray 不是有效的 ELF 文件！"
    echo "---- 文件前 200 字节内容 ----"
    head -c 200 "$XRAY_BIN" || true
    echo -e "\n----------------------------------"
    echo "下载失败或 GitHub 被限流，请重试或手动上传 Xray-linux-64 到当前目录。"
    exit 1
  fi
}

generate_vless_reality_config() {
  local server_ip="$1"
  echo "🔑 生成 Reality 密钥对..."
  local key_output
  key_output=$("$XRAY_BIN" x25519 2>/dev/null || true)

  local priv_key pub_key
  priv_key=$(echo "$key_output" | grep "Private key" | awk '{print $3}')
  pub_key=$(echo "$key_output" | grep "Public key" | awk '{print $3}')
  if [[ -z "$priv_key" || -z "$pub_key" ]]; then
    echo "❌ Reality 密钥生成失败，xray 输出如下："
    echo "$key_output"
    exit 1
  fi

  local short_id
  short_id=$(openssl rand -hex 8)

cat > "$XRAY_CONF" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": 443,
    "listen": "0.0.0.0",
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
        "dest": "www.bing.com:443",
        "xver": 0,
        "serverNames": ["${MASQ_DOMAIN}"],
        "privateKey": "${priv_key}",
        "shortIds": ["${short_id}"]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

cat > vless_reality_info.txt <<EOF
VLESS Reality 节点信息：
=============================
UUID: ${VLESS_UUID}
私钥: ${priv_key}
公钥: ${pub_key}
ShortID: ${short_id}
SNI: ${MASQ_DOMAIN}
端口: 443
=============================

v2rayN 导入链接：
vless://${VLESS_UUID}@${server_ip}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${MASQ_DOMAIN}&fp=chrome&pbk=${pub_key}&sid=${short_id}#VLESS-Reality-${server_ip}
EOF

  echo "✅ Reality 节点信息已生成：vless_reality_info.txt"
}

run_vless() {
  echo "🚀 启动 VLESS Reality..."
  "$XRAY_BIN" run -c "$XRAY_CONF" >/dev/null 2>&1 &
}

########################
# ===== 主流程 =====
########################
main() {
  read_tuic_port
  TUIC_UUID=$(uuidgen)
  TUIC_PASSWORD=$(openssl rand -hex 16)
  generate_tuic_cert
  check_tuic
  generate_tuic_config
  IP=$(curl -s https://api64.ipify.org || echo "127.0.0.1")
  generate_tuic_link "$IP"

  VLESS_UUID=$(uuidgen)
  check_xray
  generate_vless_reality_config "$IP"

  run_vless
  run_tuic
  wait
}

main "$@"
