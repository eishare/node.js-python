#!/bin/bash
# =========================================
# TUIC v1.4.5 + VLESS TCP+REALITY 自动部署（修正版）
# - 完全移除 uuidgen 依赖（使用 gen_uuid()）
# - 更稳健的 Xray 下载与 ELF 校验
# - Reality 密钥生成与校验
# =========================================

set -euo pipefail
export LC_ALL=C
IFS=$'\n\t'

# ---- 配置项（需要时可修改） ----
MASQ_DOMAIN="www.bing.com"
TUIC_VERSION="v1.4.5"
XRAY_VERSION="v25.10.15"

# ---- 文件/路径 ----
TUIC_BIN="./tuic-server"
TUIC_TOML="./server.toml"
TUIC_CERT="./tuic-cert.pem"
TUIC_KEY="./tuic-key.pem"
TUIC_LINK="./tuic_link.txt"

XRAY_BIN="./xray"
XRAY_CONF="./xray.json"
REALITY_KEY_FILE="./reality_key.txt"
VLESS_INFO="./vless_reality_info.txt"

# ---- 通用辅助函数 ----
gen_uuid() {
  # 优先 /proc/sys/kernel/random/uuid，其次 openssl 生成仿 UUID
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
    return
  fi
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
    return
  fi
  # fallback: openssl 生成并格式化为 UUID 风格
  openssl rand -hex 16 | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/'
}

fetch_to() {
  local url="$1"; local out="$2"
  # 先尝试直接下载
  if curl -L --connect-timeout 10 -m 60 -o "$out" "$url"; then
    return 0
  fi
  # 失败则尝试 ghproxy 镜像
  echo "⚠️ 主源下载失败，尝试 ghproxy..."
  if curl -L --connect-timeout 10 -m 60 -o "$out" "https://ghproxy.com/$url"; then
    return 0
  fi
  return 1
}

# ---- TUIC 部分 ----
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
    chmod 600 "$TUIC_KEY" || true
    chmod 644 "$TUIC_CERT" || true
  fi
}

check_tuic() {
  if [[ ! -x "$TUIC_BIN" ]]; then
    echo "📥 下载 TUIC..."
    fetch_to "https://github.com/Itsusinn/tuic/releases/download/${TUIC_VERSION}/tuic-server-x86_64-linux" "$TUIC_BIN" || {
      echo "❌ 无法下载 TUIC，请检查网络或手动放置可执行文件 ./tuic-server"
      exit 1
    }
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
  echo "🚀 启动 TUIC (后台)..."
  nohup "$TUIC_BIN" -c "$TUIC_TOML" >/dev/null 2>&1 &
}

# ---- VLESS Reality 部分 ----
check_xray() {
  if [[ ! -x "$XRAY_BIN" || ! -s "$XRAY_BIN" ]]; then
    echo "📥 下载 Xray-core ${XRAY_VERSION}..."
    # 直接下载二进制文件
    fetch_to "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64" "$XRAY_BIN" || {
      echo "❌ 无法下载 Xray-core，请检查网络或使用手动上传 ./xray"
      exit 1
    }
    chmod +x "$XRAY_BIN" || true
  fi

  # 验证是否为 ELF 可执行文件（若系统无 file，则跳过此检测）
  if command -v file >/dev/null 2>&1; then
    if ! file "$XRAY_BIN" 2>/dev/null | grep -qi 'elf'; then
      echo "❌ 下载的 xray 不是 ELF 可执行文件，请检查下载输出（前200字）："
      head -c 200 "$XRAY_BIN" || true
      exit 1
    fi
  fi
}

generate_reality_keys() {
  echo "🔑 使用 xray 生成 Reality 密钥对（x25519）..."
  # xray x25519 会输出 Private key: ... 和 Public key: ...
  if ! "$XRAY_BIN" x25519 > "$REALITY_KEY_FILE" 2>/dev/null; then
    echo "❌ 调用 '$XRAY_BIN x25519' 失败，确保 ./xray 支持 x25519 子命令并有可执行权限。"
    echo "xray 文件类型："
    file "$XRAY_BIN" || true
    exit 1
  fi

  PRIVATE_KEY=$(grep -i "Private key" "$REALITY_KEY_FILE" | awk -F': ' '{print $2}' | tr -d '\r\n')
  PUBLIC_KEY=$(grep -i "Public key" "$REALITY_KEY_FILE" | awk -F': ' '{print $2}' | tr -d '\r\n')

  if [[ -z "${PRIVATE_KEY:-}" || -z "${PUBLIC_KEY:-}" ]]; then
    echo "❌ 未能从 xray x25519 输出中读取私钥或公钥，输出如下："
    cat "$REALITY_KEY_FILE"
    exit 1
  fi

  echo "🔐 Reality keys OK."
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
Link (示例，适用于支持 Reality 的客户端):
vless://${VLESS_UUID}@${server_ip}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${MASQ_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}#VLESS-REALITY
========================
EOF
  echo "🔗 VLESS Reality 信息已写入：$VLESS_INFO"
  cat "$VLESS_INFO"
}

run_vless() {
  echo "🚀 启动 Xray (VLESS Reality) 后台..."
  nohup "$XRAY_BIN" run -c "$XRAY_CONF" >/dev/null 2>&1 &
}

# ---- 主流程 ----
main() {
  # 读取 / 随机 TUIC 端口
  read_tuic_port

  # 生成 UUID（不依赖 uuidgen）
  TUIC_UUID=$(gen_uuid)
  VLESS_UUID=$(gen_uuid)
  TUIC_PASSWORD=$(openssl rand -hex 16)

  # TUIC 流程
  generate_tuic_cert
  check_tuic
  generate_tuic_config
  local ip
  ip=$(curl -s https://api64.ipify.org || echo "127.0.0.1")
  generate_tuic_link "$ip"

  # VLESS Reality 流程
  check_xray
  generate_reality_keys
  generate_vless_config
  generate_vless_link

  # 启动服务
  run_vless
  run_tuic

  echo "🎉 部署完成。请检查文件："
  echo " - $TUIC_LINK"
  echo " - $VLESS_INFO"
  echo ""
  echo "若 xray 未能启动，请在终端执行：./xray run -c ./xray.json"
}

main "$@"
