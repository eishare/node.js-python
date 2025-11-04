#!/bin/bash
# =========================================
# TUIC v1.4.5 + VLESS TCP+Reality 自动部署脚本（Node.js 容器适用）
# 修正版：修复 Xray 下载/检测 与 Reality 密钥生成错误
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
    chmod +x "$TUIC_BIN" || true
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
task_negotiation_timeout = "4s"
gc_interval = "8s"
gc_lifetime = "8s"
max_external_packet_size = 8192

[users]
${TUIC_UUID} = "${TUIC_PASSWORD}"

[tls]
certificate = "$TUIC_CERT"
private_key = "$TUIC_KEY"
alpn = ["h3"]

[restful]
addr = "127.0.0.1:${TUIC_PORT}"
secret = "$(openssl rand -hex 16)"
maximum_clients_per_user = 999999999

[quic]
initial_mtu = $((1200 + RANDOM % 200))
min_mtu = 1200
gso = true
pmtu = true
send_window = 33554432
receive_window = 16777216
max_idle_time = "25s"

[quic.congestion_control]
controller = "bbr"
initial_window = 6291456
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
# 注意：XRAY_VER 只保留数字部分，下载 URL 中再加 v 前缀
XRAY_VER="25.10.15"
XRAY_BIN="./xray"
XRAY_CONF="./xray.json"

check_xray() {
  if [[ ! -x "$XRAY_BIN" || ! -s "$XRAY_BIN" ]]; then
    echo "📥 下载 Xray-core v${XRAY_VER}..."
    # 使用 -s 静默下载并写入文件
    curl -L -s -o "$XRAY_BIN" "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/Xray-linux-64" || true
    chmod +x "$XRAY_BIN" || true
  fi

  # 基本校验：确保是 ELF 可执行文件
  if command -v file >/dev/null 2>&1; then
    if ! file "$XRAY_BIN" 2>/dev/null | grep -qi 'ELF'; then
      echo "❌ 下载的 xray 不是可执行二进制，可能为 HTML/error 页面。"
      echo "---- 前 200 字节（用于诊断） ----"
      head -c 200 "$XRAY_BIN" || true
      echo "---------------------------------"
      echo "请检查网络或 GitHub Releases 是否可访问，或手动上传正确的 xray 二进制到当前目录并重试。"
      exit 1
    fi
  else
    echo "⚠️ 系统缺少 file 命令，无法校验 xray 二进制，请手动确认 ./xray 是正确的 ELF 可执行文件。"
  fi
}

generate_vless_reality_config() {
  local server_ip="$1"

  echo "🔑 使用 xray 生成 Reality 密钥对..."
  # 尝试运行 xray x25519，并捕获输出
  local key_output
  key_output=$("$XRAY_BIN" x25519 2>/dev/null || true)

  # 验证输出是否包含 Private key
  local priv_key
  local pub_key
  if echo "$key_output" | grep -q "Private key"; then
    priv_key=$(echo "$key_output" | grep "Private key" | awk -F': ' '{print $2}' | tr -d '\r\n')
    pub_key=$(echo "$key_output" | grep "Public key" | awk -F': ' '{print $2}' | tr -d '\r\n')
  else
    echo "❌ 无法通过 './xray x25519' 生成密钥。xray 输出如下："
    echo "---- xray x25519 输出开始 ----"
    echo "$key_output" || true
    echo "---- xray x25519 输出结束 ----"
    echo "请检查 ./xray 是否为正确版本（应支持 x25519 子命令），或手动在宿主机生成密钥并编辑 xray.json。"
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
私钥 (privateKey): ${priv_key}
公钥 (publicKey): ${pub_key}
ShortID: ${short_id}
SNI: ${MASQ_DOMAIN}
端口: 443
=============================

v2rayN / Nekoray 节点导入链接示例：
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
  # TUIC
  read_tuic_port
  TUIC_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
  TUIC_PASSWORD="$(openssl rand -hex 16)"
  generate_tuic_cert
  check_tuic
  generate_tuic_config
  IP=$(curl -s https://api64.ipify.org || echo "127.0.0.1")
  generate_tuic_link "$IP"

  # VLESS Reality
  VLESS_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
  check_xray
  generate_vless_reality_config "$IP"

  # 启动服务
  run_vless
  run_tuic
  wait
}

main "$@"
