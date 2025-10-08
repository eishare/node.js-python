#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# TUIC v5 自动部署脚本（支持守护 + 一键卸载）
# 适配 Alpine/Ubuntu/Debian 系统
# 使用方式: bash tuic-deploy.sh <PORT>
# 一键卸载: bash tuic-deploy.sh uninstall

set -euo pipefail
IFS=$'\n\t'

# ===================== 全局配置 =====================
TUIC_VERSION="1.5.2"
MASQ_DOMAIN="www.bing.com"        # 伪装域名
TUIC_DIR="$HOME/tuic"
SERVER_TOML="$TUIC_DIR/server.toml"
CERT_PEM="$TUIC_DIR/tuic-cert.pem"
KEY_PEM="$TUIC_DIR/tuic-key.pem"
LINK_TXT="$TUIC_DIR/tuic_link.txt"
TUIC_BIN="$TUIC_DIR/tuic-server"
PID_FILE="$TUIC_DIR/tuic.pid"

# ===================== 卸载功能 =====================
uninstall() {
    echo "⚠️ 检测到卸载命令，开始清理 TUIC..."
    if [[ -f "$PID_FILE" ]]; then
        PID=$(cat "$PID_FILE")
        kill "$PID" 2>/dev/null || true
        rm -f "$PID_FILE"
    fi
    rm -rf "$TUIC_DIR"
    echo "✅ TUIC 已成功卸载。"
    exit 0
}

# ===================== 系统依赖安装 =====================
install_dependencies() {
    echo "🔍 检查系统依赖..."
    if command -v apk >/dev/null; then
        apk update >/dev/null
        apk add --no-cache bash curl openssl coreutils grep sed util-linux || true
    elif command -v apt >/dev/null; then
        apt update -qq >/dev/null
        DEBIAN_FRONTEND=noninteractive apt install -y curl openssl uuid-runtime procps >/dev/null
    elif command -v yum >/dev/null; then
        yum install -y curl openssl util-linux procps >/dev/null
    else
        echo "⚠️ 系统不支持自动安装依赖，请手动安装 curl openssl uuidgen"
    fi
    echo "✅ 依赖安装完成"
}

# ===================== 创建目录 =====================
prepare_dir() {
    mkdir -p "$TUIC_DIR"
}

# ===================== 获取端口 =====================
TUIC_PORT=""
if [[ "${1:-}" == "uninstall" ]]; then
    uninstall
fi

if [[ $# -ge 1 && -n "${1:-}" ]]; then
    TUIC_PORT="$1"
else
    read -rp "⚙️ 请输入 TUIC 端口(1024-65535): " TUIC_PORT
fi

# ===================== 生成证书 =====================
generate_cert() {
    if [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]]; then
        echo "🔐 检测到证书，跳过生成"
        return
    fi
    echo "🔐 生成自签 ECDSA-P256 证书..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
    chmod 600 "$KEY_PEM" && chmod 644 "$CERT_PEM"
    echo "✅ 自签证书生成完成"
}

# ===================== 下载 TUIC =====================
download_tuic() {
    if [[ -x "$TUIC_BIN" ]]; then
        echo "✅ tuic-server 已存在，跳过下载"
        return
    fi
    echo "⚙️ 检测系统架构..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) ARCH="x86_64";;
        aarch64|arm64) ARCH="aarch64";;
        *) echo "❌ 暂不支持架构: $ARCH"; exit 1;;
    esac

    # 检测 C 库类型
    C_LIB=""
    if [[ -f /etc/alpine-release ]] || ldd /bin/sh 2>&1 | grep -q musl; then
        C_LIB="-musl"
    fi

    TUIC_URL="https://github.com/Itsusinn/tuic/releases/download/v${TUIC_VERSION}/tuic-server-${ARCH}-linux${C_LIB}"
    echo "⬇️ 下载 TUIC: $TUIC_URL"
    curl -L -f -o "$TUIC_BIN" "$TUIC_URL" || { echo "❌ 下载失败，请手动访问 $TUIC_URL"; exit 1; }
    chmod +x "$TUIC_BIN"
    echo "✅ TUIC 下载完成并赋予执行权限"
}

# ===================== 生成配置 =====================
generate_config() {
    TUIC_UUID="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)"
    TUIC_PASSWORD="$(openssl rand -hex 16)"
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
    echo "✅ 配置文件生成完成: $SERVER_TOML"
}

# ===================== 生成 TUIC 链接 =====================
generate_link() {
    SERVER_IP=$(curl -s --connect-timeout 5 https://api.ipify.org || echo "YOUR_SERVER_IP")
    cat > "$LINK_TXT" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${SERVER_IP}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${SERVER_IP}
EOF
    echo "📱 TUIC 链接已生成: $LINK_TXT"
    cat "$LINK_TXT"
}

# ===================== 启动守护进程 =====================
start_tuic_daemon() {
    echo "🚀 启动 TUIC 服务守护进程..."
    # 使用后台循环 + PID 文件
    nohup bash -c "while true; do $TUIC_BIN -c $SERVER_TOML; sleep 5; done" >/dev/null 2>&1 &
    echo $! > "$PID_FILE"
    echo "✅ TUIC 已启动，PID: $(cat $PID_FILE)"
}

# ===================== 主逻辑 =====================
main() {
    install_dependencies
    prepare_dir
    generate_cert
    download_tuic
    generate_config
    generate_link
    start_tuic_daemon
    echo "🎉 TUIC 部署完成！"
    echo "📄 配置文件: $SERVER_TOML"
    echo "🔗 链接文件: $LINK_TXT"
    echo "⚙️ 启动脚本目录: $TUIC_DIR"
    echo "⚡ 可执行命令: cat $LINK_TXT 查看节点链接"
}

main "$@"
