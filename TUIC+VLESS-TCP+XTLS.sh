#!/bin/bash
# =========================================
# 一键部署 TUIC + VLESS (支持单独/组合部署)
# 适用于 Node.js / Java / 无 root 环境
# 作者：eishare (GitHub)
# =========================================
set -euo pipefail
export LC_ALL=C
IFS=$'\n\t'

WORK_DIR="/home/container"
cd "$WORK_DIR"

MASQ_DOMAIN="www.bing.com"
LINK_FILE="links.txt"

TUIC_BIN="./tuic-server"
XRAY_BIN="./xray"

TUIC_CONF="server.toml"
XRAY_CONF="config.json"

CERT_TUIC="tuic-cert.pem"
KEY_TUIC="tuic-key.pem"
CERT_VLESS="vless-cert.pem"
KEY_VLESS="vless-key.pem"

# =========================================
# 工具函数
# =========================================
random_port() { echo $(( (RANDOM % 40000) + 20000 )); }
uuid_gen() { cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen; }

# 获取公网IP
get_ip() {
  curl -s --connect-timeout 3 https://api64.ipify.org || echo "127.0.0.1"
}

# =========================================
# 下载二进制
# =========================================
install_tuic() {
  if [[ ! -x "$TUIC_BIN" ]]; then
    echo "📥 Downloading tuic-server..."
    curl -L -o "$TUIC_BIN" "https://github.com/Itsusinn/tuic/releases/download/v1.4.5/tuic-server-x86_64-linux"
    chmod +x "$TUIC_BIN"
  fi
}

install_xray() {
  if [[ ! -x "$XRAY_BIN" ]]; then
    echo "📥 Downloading Xray-core..."
    XRAY_VER=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep tag_name | cut -d '"' -f4)
    curl -L -o "$XRAY_BIN" "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-64.zip"
    unzip -qo Xray-linux-64.zip xray && rm -f Xray-linux-64.zip
    chmod +x "$XRAY_BIN"
  fi
}

# =========================================
# 生成自签证书
# =========================================
generate_cert() {
  local cert=$1 key=$2
  if [[ -f "$cert" && -f "$key" ]]; then
    echo "🔐 Certificate exists: $cert"
    return
  fi
  echo "🔐 Generating certificate for $MASQ_DOMAIN..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$key" -out "$cert" -subj "/CN=$MASQ_DOMAIN" -days 365 -nodes >/dev/null 2>&1
  chmod 600 "$key"
  chmod 644 "$cert"
}

# =========================================
# 生成 TUIC 配置
# =========================================
generate_tuic_config() {
  local uuid="$1"
  local pass="$2"
  local port="$3"

cat > "$TUIC_CONF" <<EOF
log_level = "warn"
server = "0.0.0.0:${port}"
udp_relay_ipv6 = false
zero_rtt_handshake = true
auth_timeout = "8s"

[users]
${uuid} = "${pass}"

[tls]
certificate = "$CERT_TUIC"
private_key = "$KEY_TUIC"
alpn = ["h3"]
EOF
}

# =========================================
# 生成 VLESS 配置
# =========================================
generate_vless_config() {
  local uuid="$1"

cat > "$XRAY_CONF" <<EOF
{
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "xtls",
        "xtlsSettings": {
          "alpn": ["http/1.1"],
          "certificates": [
            {
              "certificateFile": "${CERT_VLESS}",
              "keyFile": "${KEY_VLESS}"
            }
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

# =========================================
# 启动守护进程
# =========================================
run_tuic() {
  echo "🚀 Starting TUIC..."
  nohup "$TUIC_BIN" -c "$TUIC_CONF" >/dev/null 2>&1 &
}

run_xray() {
  echo "🚀 Starting Xray..."
  nohup "$XRAY_BIN" run -c "$XRAY_CONF" >/dev/null 2>&1 &
}

# =========================================
# 输出节点链接
# =========================================
output_links() {
  local ip="$1" tuic_uuid="$2" tuic_pass="$3" tuic_port="$4" vless_uuid="$5"

  echo "🔗 Generating share links..."
  {
    echo "======================="
    echo "TUIC:"
    echo "tuic://${tuic_uuid}:${tuic_pass}@${ip}:${tuic_port}?congestion_control=bbr&alpn=h3&sni=${MASQ_DOMAIN}&udp_relay_mode=native#TUIC-${ip}"
    echo
    echo "VLESS:"
    echo "vless://${vless_uuid}@${ip}:443?security=xtls&type=tcp&flow=xtls-rprx-vision&sni=${MASQ_DOMAIN}#VLESS-${ip}"
    echo "======================="
  } > "$LINK_FILE"

  cat "$LINK_FILE"
}

# =========================================
# 主程序逻辑
# =========================================
main() {
  echo "请选择部署模式："
  echo "1️⃣ 仅部署 TUIC"
  echo "2️⃣ 仅部署 VLESS"
  echo "3️⃣ 同时部署 TUIC + VLESS"
  read -rp "请输入选项 [1-3]: " MODE

  ip="$(get_ip)"
  tuic_uuid="$(uuid_gen)"
  tuic_pass="$(openssl rand -hex 16)"
  vless_uuid="$(uuid_gen)"
  tuic_port=$(random_port)

  case "$MODE" in
    1)
      install_tuic
      generate_cert "$CERT_TUIC" "$KEY_TUIC"
      generate_tuic_config "$tuic_uuid" "$tuic_pass" "$tuic_port"
      run_tuic
      output_links "$ip" "$tuic_uuid" "$tuic_pass" "$tuic_port" "$vless_uuid"
      ;;
    2)
      install_xray
      generate_cert "$CERT_VLESS" "$KEY_VLESS"
      generate_vless_config "$vless_uuid"
      run_xray
      output_links "$ip" "$tuic_uuid" "$tuic_pass" "$tuic_port" "$vless_uuid"
      ;;
    3)
      install_tuic
      install_xray
      generate_cert "$CERT_TUIC" "$KEY_TUIC"
      generate_cert "$CERT_VLESS" "$KEY_VLESS"
      generate_tuic_config "$tuic_uuid" "$tuic_pass" "$tuic_port"
      generate_vless_config "$vless_uuid"
      run_tuic
      run_xray
      output_links "$ip" "$tuic_uuid" "$tuic_pass" "$tuic_port" "$vless_uuid"
      ;;
    *)
      echo "❌ 无效选项"; exit 1;;
  esac
}

main
