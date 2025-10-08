#!/usr/bin/env bash
# TUIC 自动部署脚本 v1.0
# 支持 Ubuntu/Debian/Alpine 自动识别 glibc/musl 二进制
# 支持命令行端口参数
# 适用于 x86_64 架构

set -euo pipefail
IFS=$'\n\t'

# ----------------- 配置 -----------------
TUIC_DIR="$HOME/tuic"
TUIC_VERSION="1.5.2"
CERT_FILE="$TUIC_DIR/tuic-cert.pem"
KEY_FILE="$TUIC_DIR/tuic-key.pem"
CONFIG_FILE="$TUIC_DIR/server.toml"
TUIC_BIN="$TUIC_DIR/tuic-server"
LINK_FILE="$TUIC_DIR/tuic_link.txt"
SNI="www.bing.com"
ALPN="h3"
# ---------------------------------------

mkdir -p "$TUIC_DIR"

# ----------------- 端口 -----------------
if [[ $# -ge 1 && -n "${1:-}" ]]; then
    PORT="$1"
else
    PORT=24568
fi
echo "✅ 使用端口: $PORT"

# ----------------- 系统检测 -----------------
detect_system() {
    if command -v lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
    elif [[ -f /etc/os-release ]]; then
        OS=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
    else
        OS="unknown"
    fi

    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        ARCH="x86_64"
    else
        echo "❌ 当前架构不支持: $ARCH"
        exit 1
    fi

    # 判断 C 库
    if [[ "$OS" == "alpine" ]]; then
        LIB_SUFFIX="-musl"
    else
        LIB_SUFFIX=""
    fi

    echo "🔍 系统: $OS, 架构: $ARCH, C库后缀: $LIB_SUFFIX"
}

# ----------------- 安装依赖 -----------------
install_dependencies() {
    echo "🔧 检查并安装依赖..."
    if command -v apk >/dev/null; then
        apk update >/dev/null
        apk add --no-cache curl openssl coreutils grep sed util-linux >/dev/null
    elif command -v apt >/dev/null; then
        apt update -qq >/dev/null
        apt install -y curl openssl uuid-runtime >/dev/null
    elif command -v yum >/dev/null; then
        yum install -y curl openssl util-linux >/dev/null
    fi
    echo "✅ 依赖安装完成"
}

# ----------------- 生成证书 -----------------
generate_cert() {
    if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        echo "🔐 已存在证书，跳过生成"
        return
    fi
    echo "🔐 生成自签 ECDSA-P256 证书..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${SNI}" -days 365 -nodes >/dev/null 2>&1
    chmod 600 "$KEY_FILE" "$CERT_FILE"
    echo "✅ 证书生成完成"
}

# ----------------- 下载 TUIC -----------------
download_tuic() {
    if [[ -x "$TUIC_BIN" ]]; then
        echo "✅ TUIC 二进制已存在，跳过下载"
        return
    fi

    URL="https://github.com/Itsusinn/tuic/releases/download/v${TUIC_VERSION}/tuic-server-${ARCH}-linux${LIB_SUFFIX}"
    echo "⬇️ 下载 TUIC: $URL"
    curl -L -f -o "$TUIC_BIN" "$URL"
    chmod +x "$TUIC_BIN"
    echo "✅ TUIC 下载完成"
}

# ----------------- 生成配置 -----------------
generate_config() {
    UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    PASSWORD=$(openssl rand -hex 16)

    cat > "$CONFIG_FILE" <<EOF
log_level = "off"
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
${UUID} = "${PASSWORD}"

[tls]
self_sign = false
certificate = "$CERT_FILE"
private_key = "$KEY_FILE"
alpn = ["$ALPN"]

[restful]
addr = "127.0.0.1:${PORT}"
secret = "$(openssl rand -hex 16)"
maximum_clients_per_user = 999999999

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

    echo "✅ 配置文件生成完成: $CONFIG_FILE"

    # 生成 TUIC 链接
    IP=$(curl -s https://api.ipify.org || echo "YOUR_SERVER_IP")
    cat > "$LINK_FILE" <<EOF
tuic://${UUID}:${PASSWORD}@${IP}:${PORT}?congestion_control=bbr&alpn=${ALPN}&allowInsecure=1&sni=${SNI}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1#TUIC-${IP}
EOF
    echo "📱 TUIC 链接已生成: $LINK_FILE"
}

# ----------------- 启动 TUIC -----------------
start_tuic() {
    echo "🚀 启动 TUIC 服务..."
    nohup "$TUIC_BIN" -c "$CONFIG_FILE" >/dev/null 2>&1 &
    sleep 1
    if ! pgrep -f tuic-server >/dev/null; then
        echo "❌ TUIC 启动失败，请检查日志或二进制兼容性"
        exit 1
    fi
    echo "✅ TUIC 已启动"
}

# ----------------- 主函数 -----------------
main() {
    detect_system
    install_dependencies
    generate_cert
    download_tuic
    generate_config
    start_tuic

    echo "🎉 TUIC 部署完成！"
    echo "📄 配置文件: $CONFIG_FILE"
    echo "🔗 链接文件: $LINK_FILE"
    echo "⚙️ 启动脚本目录: $TUIC_DIR"
}

main "$@"
