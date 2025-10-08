#!/bin/bash
# =============================================================
# 🌀 TUIC v1.5.9 极简自动部署（支持 Claw Cloud、Alpine、Glibc）
# 支持挂载持久目录，防止爪云重启后数据丢失
# 作者：eishare | 更新时间：2025-10-09
# =============================================================
set -euo pipefail
IFS=$'\n\t'

# ---------------- 用户可修改区 ----------------
MASQ_DOMAIN="www.bing.com"    # 伪装域名
INSTALL_DIR="/root/tuic"      # 持久目录（建议挂载）
TUIC_VERSION="1.5.9"
SERVER_TOML="${INSTALL_DIR}/server.toml"
CERT_PEM="${INSTALL_DIR}/tuic-cert.pem"
KEY_PEM="${INSTALL_DIR}/tuic-key.pem"
LINK_TXT="${INSTALL_DIR}/tuic_link.txt"
START_SH="${INSTALL_DIR}/start.sh"
TUIC_BIN="${INSTALL_DIR}/tuic-server"
# ------------------------------------------------------------

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ========== 检查依赖 ==========
echo "🔍 检查系统依赖..."
if command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl openssl coreutils grep sed >/dev/null
elif command -v apt >/dev/null 2>&1; then
    apt update -qq >/dev/null
    apt install -y curl openssl uuid-runtime >/dev/null
else
    echo "⚠️ 未检测到支持的包管理器，请确保已安装 curl openssl uuidgen"
fi
echo "✅ 依赖检查完成"

# ========== 获取端口 ==========
if [[ $# -ge 1 ]]; then
    TUIC_PORT="$1"
else
    TUIC_PORT=443
fi
echo "✅ 使用端口: $TUIC_PORT"

# ========== 生成 UUID & 密码 ==========
if [[ -f "$SERVER_TOML" ]]; then
    echo "📂 检测到已有配置，加载中..."
    TUIC_UUID=$(grep '^\[users\]' -A1 "$SERVER_TOML" | tail -n1 | awk '{print $1}')
    TUIC_PASSWORD=$(grep '^\[users\]' -A1 "$SERVER_TOML" | tail -n1 | awk -F'"' '{print $2}')
else
    TUIC_UUID="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
    TUIC_PASSWORD="$(openssl rand -hex 16)"
fi
echo "🔑 UUID: $TUIC_UUID"
echo "🔑 密码: $TUIC_PASSWORD"
echo "🎯 SNI: ${MASQ_DOMAIN}"

# ========== 生成证书 ==========
if [[ ! -f "$CERT_PEM" || ! -f "$KEY_PEM" ]]; then
    echo "🔐 生成自签证书..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -days 3650 -nodes -keyout "$KEY_PEM" -out "$CERT_PEM" \
      -subj "/CN=${MASQ_DOMAIN}" >/dev/null 2>&1
    echo "✅ 证书生成完成"
else
    echo "✅ 检测到已有证书，跳过生成"
fi

# ========== 检测架构与C库 ==========
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) ARCH="x86_64" ;;
    aarch64|arm64) ARCH="aarch64" ;;
    *) echo "❌ 不支持的架构: $ARCH"; exit 1 ;;
esac

if ldd /bin/sh 2>&1 | grep -q musl; then
    C_LIB="-musl"
    echo "⚙️ 检测到系统使用 musl (Alpine)"
else
    C_LIB=""
    echo "⚙️ 检测到系统使用 glibc (Ubuntu/Debian)"
fi

# ========== 下载 TUIC ==========
TUIC_URL="https://github.com/Itsusinn/tuic/releases/download/v${TUIC_VERSION}/tuic-server-${ARCH}-linux${C_LIB}"
echo "⬇️ 下载 TUIC: $TUIC_URL"
if ! curl -Lf -o "$TUIC_BIN" "$TUIC_URL"; then
    echo "❌ 下载失败，请检查版本或手动下载 $TUIC_URL"
    exit 1
fi
chmod +x "$TUIC_BIN"
echo "✅ TUIC 下载完成并已赋予执行权限"

# ========== 生成配置文件 ==========
cat > "$SERVER_TOML" <<EOF
log_level = "off"
server = "0.0.0.0:${TUIC_PORT}"

udp_relay_ipv6 = false
zero_rtt_handshake = true
dual_stack = false
auth_timeout = "10s"
task_negotiation_timeout = "5s"
gc_interval = "10s"
gc_lifetime = "10s"
max_external_packet_size = 8192

[users]
${TUIC_UUID} = "${TUIC_PASSWORD}"

[tls]
self_sign = false
certificate = "${CERT_PEM}"
private_key = "${KEY_PEM}"
alpn = ["h3"]

[quic]
initial_mtu = 1500
min_mtu = 1200
gso = true
pmtu = true
send_window = 33554432
receive_window = 16777216
max_idle_time = "20s"
congestion_control = { controller = "bbr", initial_window = 4194304 }
EOF

echo "✅ 生成配置文件: ${SERVER_TOML}"

# ========== 获取公网 IP ==========
SERVER_IP=$(curl -s --connect-timeout 5 https://api.ipify.org || echo "YOUR_SERVER_IP")

# ========== 生成 TUIC 链接 ==========
cat > "$LINK_TXT" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${SERVER_IP}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${SERVER_IP}
EOF
echo "📱 TUIC 链接已生成："
cat "$LINK_TXT"

# ========== 创建启动脚本 ==========
cat > "$START_SH" <<EOF
#!/bin/bash
cd "$INSTALL_DIR"
if [[ -x "$TUIC_BIN" ]]; then
  nohup "$TUIC_BIN" -c "$SERVER_TOML" >/dev/null 2>&1 &
  echo "✅ TUIC 已启动"
else
  echo "❌ 找不到可执行文件 $TUIC_BIN"
fi
EOF
chmod +x "$START_SH"
echo "✅ 启动脚本生成完成: $START_SH"

# ========== 启动 TUIC ==========
echo "🚀 启动 TUIC 服务中..."
"$START_SH"

echo "🎉 TUIC 节点部署成功！"
echo "----------------------------------------"
echo "📂 安装目录: $INSTALL_DIR"
echo "📄 配置文件: $SERVER_TOML"
echo "🔗 节点链接已保存到: $LINK_TXT"
echo "⚙️ 启动脚本: $START_SH"
echo "----------------------------------------"
