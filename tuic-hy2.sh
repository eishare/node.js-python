#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# TUIC 自动部署、守护、自恢复脚本
# 适用：Alpine / Ubuntu / Debian
# 功能：自动部署 TUIC、自动重启、重启容器自动恢复、生成节点链接、一键卸载

set -euo pipefail
IFS=$'\n\t'

# ===================== 配置 =====================
TUIC_DIR="/root/tuic"
TUIC_VERSION="1.5.2"
MASQ_DOMAIN="www.bing.com"
TUIC_PORT="${1:-24568}"  # 可通过命令行参数指定端口
SERVER_TOML="${TUIC_DIR}/server.toml"
CERT_PEM="${TUIC_DIR}/tuic-cert.pem"
KEY_PEM="${TUIC_DIR}/tuic-key.pem"
LINK_TXT="${TUIC_DIR}/tuic_link.txt"
TUIC_BIN="${TUIC_DIR}/tuic-server"

# ===================== 检查系统依赖 =====================
install_dependencies() {
    echo "🔧 检查并安装依赖..."
    if command -v apk >/dev/null; then
        apk add --no-cache bash curl openssl util-linux || { echo "❌ Alpine依赖安装失败"; exit 1; }
    elif command -v apt >/dev/null; then
        apt update -qq
        DEBIAN_FRONTEND=noninteractive apt install -y curl openssl uuid-runtime >/dev/null
    elif command -v yum >/dev/null; then
        yum install -y curl openssl uuid
    else
        echo "⚠️ 无法自动安装依赖，请手动安装 curl、openssl、uuidgen"
    fi
    echo "✅ 依赖检查完成"
}

# ===================== 生成证书 =====================
generate_cert() {
    mkdir -p "$TUIC_DIR"
    if [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]]; then
        echo "🔐 证书已存在，跳过生成"
        return
    fi
    echo "🔐 生成自签 ECDSA-P256 证书..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 >/dev/null 2>&1
    chmod 600 "$KEY_PEM"
    chmod 644 "$CERT_PEM"
    echo "✅ 证书生成完成"
}

# ===================== 下载 TUIC =====================
download_tuic() {
    mkdir -p "$TUIC_DIR"
    echo "⬇️ 下载 TUIC..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)
            ARCH="x86_64"
            ;;
        aarch64|arm64)
            ARCH="aarch64"
            ;;
        *)
            echo "❌ 暂不支持架构: $ARCH"; exit 1
            ;;
    esac

    # 判断 C 库类型
    if [[ -f /etc/alpine-release ]]; then
        C_LIB="-musl"
    else
        C_LIB=""
    fi

    URL="https://github.com/Itsusinn/tuic/releases/download/v${TUIC_VERSION}/tuic-server-${ARCH}-linux${C_LIB}"
    echo "⬇️ 下载链接: $URL"
    
    # 下载
    curl -L -f -o "$TUIC_BIN.tmp" "$URL" || { echo "❌ 下载失败"; exit 1; }
    chmod +x "$TUIC_BIN.tmp"
    mv "$TUIC_BIN.tmp" "$TUIC_BIN"
    echo "✅ TUIC 下载完成"
}

# ===================== 生成配置 =====================
generate_config() {
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
$TUIC_UUID = "$TUIC_PASSWORD"

[tls]
self_sign = false
certificate = "$CERT_PEM"
private_key = "$KEY_PEM"
alpn = ["h3"]

[restful]
addr = "127.0.0.1:${TUIC_PORT}"
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
    echo "✅ 配置文件生成完成"
}

# ===================== 生成节点信息 =====================
generate_link() {
    IP=$(curl -s https://api.ipify.org || echo "YOUR_SERVER_IP")
    cat > "$LINK_TXT" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${IP}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${IP}
EOF
    echo "📱 节点链接已生成: $LINK_TXT"
}

# ===================== 启动 TUIC 服务 =====================
start_tuic() {
    echo "🚀 启动 TUIC 服务..."
    nohup "$TUIC_BIN" -c "$SERVER_TOML" >/root/tuic/tuic.log 2>&1 &
    echo "✅ TUIC 已启动"
}

# ===================== 自动重启守护 =====================
auto_restart() {
    while true; do
        if ! pgrep -f "$TUIC_BIN" >/dev/null; then
            echo "⚠️ TUIC 服务未运行，正在重启..."
            nohup "$TUIC_BIN" -c "$SERVER_TOML" >/root/tuic/tuic.log 2>&1 &
        fi
        sleep 5
    done
}

# ===================== 一键卸载 =====================
uninstall_tuic() {
    echo "🗑️ 停止 TUIC 服务..."
    pkill -f "$TUIC_BIN" || true
    echo "🗑️ 删除文件..."
    rm -rf "$TUIC_DIR"
    echo "✅ TUIC 已卸载"
}

# ===================== 初始化 =====================
init() {
    mkdir -p "$TUIC_DIR"
    install_dependencies

    # UUID 与密码
    if [[ -f "$SERVER_TOML" ]]; then
        TUIC_UUID=$(grep -Po '(?<=\[users\]\n).*(?==)' "$SERVER_TOML" | tr -d ' ')
        TUIC_PASSWORD=$(grep -Po '(?<=\= ").*(?=")' "$SERVER_TOML")
    else
        TUIC_UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
        TUIC_PASSWORD=$(openssl rand -hex 16)
        echo "🔑 UUID: $TUIC_UUID"
        echo "🔑 密码: $TUIC_PASSWORD"
    fi

    generate_cert
    download_tuic
    generate_config
    generate_link
    start_tuic

    # 后台守护
    auto_restart &
    echo "🎉 TUIC 部署完成"
    echo "📄 配置文件: $SERVER_TOML"
    echo "🔗 节点链接: $LINK_TXT"
    echo "⚙️ 启动脚本目录: $TUIC_DIR"
    echo "💡 使用: bash tuic.sh uninstall 可卸载"
}

# ===================== 主逻辑 =====================
case "${1:-}" in
    uninstall)
        uninstall_tuic
        exit 0
        ;;
    *)
        init
        ;;
esac
