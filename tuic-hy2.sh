#!/bin/bash
# =========================================
# 🌀 TUIC v5 自动部署脚本 (挂载 /root/tuic)
# 兼容: Alpine / Debian / Ubuntu / Claw Cloud
# 支持: 环境变量 uuid (固定节点)
# by eishare / 2025-10
# =========================================

set -euo pipefail
IFS=$'\n\t'

TUIC_VERSION="1.5.2"
WORK_DIR="/root/tuic"
BIN_PATH="$WORK_DIR/tuic-server"
CONF_PATH="$WORK_DIR/server.toml"
CERT_PEM="$WORK_DIR/tuic-cert.pem"
KEY_PEM="$WORK_DIR/tuic-key.pem"
LINK_PATH="$WORK_DIR/tuic_link.txt"
LOG_FILE="$WORK_DIR/tuic.log"
START_SH="$WORK_DIR/start.sh"
MASQ_DOMAIN="www.bing.com"

# ------------------ 卸载 ------------------
if [[ "${1:-}" == "uninstall" ]]; then
    echo "🧹 正在卸载 TUIC..."
    pkill -f tuic-server || true
    rm -rf "$WORK_DIR"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable tuic-server.service 2>/dev/null || true
        rm -f /etc/systemd/system/tuic-server.service
        systemctl daemon-reload
    fi
    echo "✅ 卸载完成"
    exit 0
fi

# ------------------ 端口参数 ------------------
PORT="${1:-443}"

# ------------------ 检查系统 ------------------
echo "🔍 检查系统信息..."
ARCH=$(uname -m)
[[ "$ARCH" == "x86_64" || "$ARCH" == "amd64" ]] && ARCH="x86_64"
[[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && ARCH="aarch64"

if grep -qi alpine /etc/os-release; then
    C_LIB_SUFFIX="-linux-musl"
    PKG_INSTALL="apk add --no-cache bash curl openssl procps iproute2 net-tools"
elif command -v apt >/dev/null 2>&1; then
    C_LIB_SUFFIX="-linux"
    PKG_INSTALL="apt update -y && apt install -y curl openssl uuid-runtime procps iproute2 net-tools"
elif command -v yum >/dev/null 2>&1; then
    C_LIB_SUFFIX="-linux"
    PKG_INSTALL="yum install -y curl openssl uuid procps-ng iproute net-tools"
else
    echo "❌ 不支持的系统类型"
    exit 1
fi

# ------------------ 安装依赖 ------------------
echo "🔧 检查并安装依赖..."
eval "$PKG_INSTALL" >/dev/null 2>&1
echo "✅ 依赖安装完成"

# ------------------ 创建目录 ------------------
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# ------------------ 下载 TUIC ------------------
URL="https://github.com/Itsusinn/tuic/releases/download/v${TUIC_VERSION}/tuic-server-${ARCH}${C_LIB_SUFFIX}"
echo "⬇️ 下载 TUIC: $URL"
if curl -L -f -o "$BIN_PATH" "$URL"; then
    chmod +x "$BIN_PATH"
    echo "✅ TUIC 下载完成"
else
    echo "❌ 下载失败，请检查网络"
    exit 1
fi

# ------------------ 生成证书 ------------------
if [[ ! -f "$CERT_PEM" ]]; then
    echo "🔐 生成自签证书..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
    echo "✅ 证书生成完成"
fi

# ------------------ UUID 设置 ------------------
if [[ -n "${uuid:-}" ]]; then
    UUID="$uuid"
    echo "🔗 使用爪云环境变量 uuid: $UUID"
else
    UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    echo "⚙️ 未检测到环境变量 uuid，已自动生成: $UUID"
fi
PASS=$(openssl rand -hex 16)

# ------------------ 生成配置 ------------------
cat > "$CONF_PATH" <<EOF
log_level = "info"
server = "0.0.0.0:${PORT}"
udp_relay_ipv6 = false
zero_rtt_handshake = true
dual_stack = false
auth_timeout = "10s"
task_negotiation_timeout = "5s"
gc_interval = "10s"
gc_lifetime = "10s"
max_external_packet_size = 8192

[users]
${UUID} = "${PASS}"

[tls]
certificate = "$CERT_PEM"
private_key = "$KEY_PEM"
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

echo "✅ 配置文件生成完成: $CONF_PATH"

# ------------------ TUIC 链接 ------------------
IP=$(curl -s --connect-timeout 5 https://api.ipify.org || echo "YOUR_IP")
LINK="tuic://${UUID}:${PASS}@${IP}:${PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1#TUIC-${IP}"
echo "$LINK" > "$LINK_PATH"
echo "📱 TUIC 链接: $LINK"
echo "🔗 已保存至: $LINK_PATH"

# ------------------ 启动脚本 ------------------
cat > "$START_SH" <<EOF
#!/bin/bash
cd $WORK_DIR
while true; do
  "$BIN_PATH" -c "$CONF_PATH" >> "$LOG_FILE" 2>&1
  echo "⚠️ TUIC 已退出，5秒后自动重启..." >> "$LOG_FILE"
  sleep 5
done
EOF
chmod +x "$START_SH"

# ------------------ 守护进程 ------------------
if command -v systemctl >/dev/null 2>&1; then
    cat > /etc/systemd/system/tuic-server.service <<EOF
[Unit]
Description=TUIC Server
After=network.target

[Service]
ExecStart=$BIN_PATH -c $CONF_PATH
Restart=always
RestartSec=5
WorkingDirectory=$WORK_DIR

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable tuic-server
    systemctl restart tuic-server
    echo "🧩 已创建 systemd 服务 tuic-server"
else
    nohup bash "$START_SH" >/dev/null 2>&1 &
    echo "🌀 使用 nohup 守护 TUIC 进程"
fi

# ------------------ 防火墙 ------------------
if command -v ufw >/dev/null 2>&1; then
    ufw allow "$PORT"/tcp >/dev/null 2>&1 || true
    ufw allow "$PORT"/udp >/dev/null 2>&1 || true
elif command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT || true
    iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT || true
fi
echo "🧱 已放行 TCP/UDP 端口: $PORT"

# ------------------ 检查运行状态 ------------------
sleep 2
echo ""
echo "✅ TUIC 部署完成！"
echo "📄 配置文件: $CONF_PATH"
echo "🔗 节点链接: $LINK_PATH"
echo "📜 日志路径: $LOG_FILE"
if pgrep -f tuic-server >/dev/null; then
    echo "✅ TUIC 正在运行"
else
    echo "⚠️ TUIC 未运行，请检查日志: tail -f $LOG_FILE"
fi
