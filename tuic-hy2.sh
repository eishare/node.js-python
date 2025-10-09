#!/bin/bash
# =========================================
# TUIC v5 自动部署增强版 (支持 Alpine / Ubuntu / Debian)
# 永久持久化 + 自启动守护 + 一键卸载
# by eishare / 2025
# =========================================

set -euo pipefail
IFS=$'\n\t'

TUIC_VERSION="1.5.2"
WORK_DIR="/tuic"
LOG_DIR="/var/log/tuic"
BIN_PATH="$WORK_DIR/tuic-server"
CONF_PATH="$WORK_DIR/server.toml"
CERT_PEM="$WORK_DIR/tuic-cert.pem"
KEY_PEM="$WORK_DIR/tuic-key.pem"
LINK_PATH="$WORK_DIR/tuic_link.txt"
START_SH="$WORK_DIR/start.sh"
MASQ_DOMAIN="www.bing.com"

# ------------------ 一键卸载 ------------------
if [[ "${1:-}" == "uninstall" ]]; then
    echo "🧹 正在卸载 TUIC..."
    pkill -f tuic-server || true
    rm -rf "$WORK_DIR"
    rm -rf "$LOG_DIR"
    systemctl disable tuic-server.service 2>/dev/null || true
    rm -f /etc/systemd/system/tuic-server.service
    echo "✅ TUIC 已完全卸载。"
    exit 0
fi

# ------------------ 检查端口 ------------------
PORT="${1:-443}"

# ------------------ 检查系统类型 ------------------
echo "🔍 检查系统信息..."
ARCH=$(uname -m)
[[ "$ARCH" == "x86_64" || "$ARCH" == "amd64" ]] && ARCH="x86_64"
[[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && ARCH="aarch64"

if grep -qi alpine /etc/os-release; then
    SYS="alpine"
    C_LIB_SUFFIX="-linux-musl"
    PKG_INSTALL="apk add --no-cache bash curl openssl util-linux procps net-tools iproute2"
elif command -v apt >/dev/null 2>&1; then
    SYS="debian"
    C_LIB_SUFFIX="-linux"
    PKG_INSTALL="apt update -y && apt install -y curl openssl uuid-runtime bash procps net-tools iproute2"
elif command -v yum >/dev/null 2>&1; then
    SYS="centos"
    C_LIB_SUFFIX="-linux"
    PKG_INSTALL="yum install -y curl openssl uuid bash procps-ng net-tools iproute"
else
    echo "❌ 不支持的系统类型。"
    exit 1
fi

# ------------------ 安装依赖 ------------------
echo "🔧 检查并安装依赖..."
eval "$PKG_INSTALL" >/dev/null 2>&1 || true
echo "✅ 依赖安装完成"

# ------------------ 创建目录 ------------------
mkdir -p "$WORK_DIR" "$LOG_DIR"
cd "$WORK_DIR"

# ------------------ 下载 TUIC ------------------
URL="https://github.com/Itsusinn/tuic/releases/download/v${TUIC_VERSION}/tuic-server-${ARCH}${C_LIB_SUFFIX}"
echo "⬇️ 下载 TUIC: $URL"
if curl -L -f -o "$BIN_PATH" "$URL"; then
    chmod +x "$BIN_PATH"
    echo "✅ TUIC 下载完成"
else
    echo "❌ 下载失败，请检查网络或版本号"
    exit 1
fi

# ------------------ 生成证书 ------------------
if [[ ! -f "$CERT_PEM" ]]; then
    echo "🔐 生成自签证书..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
    echo "✅ 证书生成完成"
fi

# ------------------ 生成配置 ------------------
UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
PASS=$(openssl rand -hex 16)
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

# ------------------ 生成 TUIC 链接 ------------------
IP=$(curl -s --connect-timeout 5 https://api.ipify.org || echo "YOUR_IP")
LINK="tuic://${UUID}:${PASS}@${IP}:${PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1#TUIC-${IP}"
echo "$LINK" > "$LINK_PATH"
echo "📱 TUIC 链接: $LINK"
echo "🔗 已保存至: $LINK_PATH"

# ------------------ 创建守护启动脚本 ------------------
cat > "$START_SH" <<EOF
#!/bin/sh
mkdir -p /var/log/tuic
LOG_FILE="/var/log/tuic/tuic.log"

while true; do
    if ! pgrep -f tuic-server >/dev/null 2>&1; then
        if ! command -v curl >/dev/null 2>&1; then
            if [ -f /etc/alpine-release ]; then
                apk add --no-cache curl openssl bash procps net-tools iproute2
            elif command -v apt >/dev/null 2>&1; then
                apt update -y && apt install -y curl openssl bash procps net-tools iproute2
            fi
        fi
        nohup /tuic/tuic-server -c /tuic/server.toml >>"\$LOG_FILE" 2>&1 &
        echo "[$(date '+%F %T')] TUIC 已启动" >>"\$LOG_FILE"
    fi
    sleep 10
done
EOF
chmod +x "$START_SH"

# ------------------ 开机自启处理 ------------------
if command -v systemctl >/dev/null 2>&1; then
    cat > /etc/systemd/system/tuic-server.service <<EOF
[Unit]
Description=TUIC Server
After=network.target

[Service]
ExecStart=$BIN_PATH -c $CONF_PATH
Restart=always
RestartSec=5

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

# ------------------ 防火墙放行 ------------------
if command -v ufw >/dev/null 2>&1; then
    ufw allow "$PORT"/tcp >/dev/null 2>&1 || true
    ufw allow "$PORT"/udp >/dev/null 2>&1 || true
elif command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT || true
    iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT || true
fi
echo "🧱 已放行 TCP/UDP 端口: $PORT"

# ------------------ 显示运行状态 ------------------
sleep 1
echo ""
echo "✅ TUIC 部署完成！"
echo "📄 配置文件: $CONF_PATH"
echo "🔗 节点链接: $LINK_PATH"
echo "📜 日志路径: $LOG_DIR/tuic.log"
echo ""
echo "⚙️ 正在检查进程状态..."
if pgrep -f tuic-server >/dev/null 2>&1; then
    echo "✅ TUIC 已在运行中！"
else
    echo "⚠️ 未检测到运行，尝试执行: bash $START_SH"
fi
