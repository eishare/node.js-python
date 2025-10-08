#!/bin/bash
# TUIC v5 over QUIC 自动部署脚本（更新：部署完成直接打印节点链接）
# 兼容：Alpine (musl), Ubuntu/Debian (glibc)

set -euo pipefail
IFS=$'\n\t'

# ===================== 全局配置 =====================
MASQ_DOMAIN="www.bing.com"    # 固定伪装域名
TUIC_DIR="$HOME/tuic"
SERVER_TOML="$TUIC_DIR/server.toml"
CERT_PEM="$TUIC_DIR/tuic-cert.pem"
KEY_PEM="$TUIC_DIR/tuic-key.pem"
LINK_TXT="$TUIC_DIR/tuic_link.txt"
TUIC_BIN="$TUIC_DIR/tuic-server"
TUIC_VERSION="1.5.2"

mkdir -p "$TUIC_DIR"

# ===================== 检查依赖 =====================
check_dependencies() {
    echo "🔍 检查系统依赖..."
    if command -v apk >/dev/null; then
        apk update >/dev/null
        apk add --no-cache bash curl openssl coreutils grep sed util-linux
    elif command -v apt >/dev/null; then
        apt update -qq >/dev/null
        DEBIAN_FRONTEND=noninteractive apt install -y curl openssl uuid-runtime >/dev/null
    else
        echo "⚠️ 无法自动安装依赖，请确保已安装 curl, openssl, uuidgen"
    fi
    echo "✅ 依赖检查完成"
}

# ===================== 读取端口 =====================
read_port() {
    if [[ $# -ge 1 && -n "${1:-}" ]]; then
        TUIC_PORT="$1"
        echo "✅ 使用端口: $TUIC_PORT"
    else
        echo "⚙️ 请输入 TUIC 端口 (1024-65535):"
        read -rp "> " TUIC_PORT
    fi
}

# ===================== 生成自签证书 =====================
generate_cert() {
    if [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]]; then
        echo "🔐 检测到已有证书，跳过生成"
        return
    fi
    echo "🔐 生成自签 ECDSA-P256 证书..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
    chmod 600 "$KEY_PEM"
    chmod 644 "$CERT_PEM"
    echo "✅ 证书生成完成"
}

# ===================== 下载 tuic-server =====================
download_tuic() {
    echo "⚙️ 检测系统架构..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) ARCH="x86_64";;
        aarch64|arm64) ARCH="aarch64";;
        *) echo "❌ 不支持架构: $ARCH"; exit 1;;
    esac

    C_LIB_SUFFIX=""
    if grep -qi alpine /etc/os-release 2>/dev/null; then
        C_LIB_SUFFIX="-musl"
    fi

    TUIC_URL="https://github.com/Itsusinn/tuic/releases/download/v${TUIC_VERSION}/tuic-server-${ARCH}-linux${C_LIB_SUFFIX}"
    echo "⬇️ 下载 TUIC: $TUIC_URL"

    curl -L -f -o "$TUIC_BIN" "$TUIC_URL"
    chmod +x "$TUIC_BIN"
    echo "✅ TUIC 下载完成并赋予执行权限"
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
    echo "✅ 配置文件生成完成: $SERVER_TOML"
}

# ===================== 获取公网 IP =====================
get_server_ip() {
    curl -s --connect-timeout 5 https://api.ipify.org || echo "YOUR_SERVER_IP"
}

# ===================== 生成 TUIC 链接 =====================
generate_link() {
    local ip="$1"
    cat > "$LINK_TXT" <<EOF
tuic://$TUIC_UUID:$TUIC_PASSWORD@$ip:$TUIC_PORT?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1#TUIC-$ip
EOF

    echo ""
    echo "📱 TUIC 节点链接（直接复制使用）:"
    cat "$LINK_TXT"
}

# ===================== 启动服务 =====================
start_service() {
    echo "🚀 启动 TUIC 服务..."
    nohup "$TUIC_BIN" -c "$SERVER_TOML" >/dev/null 2>&1 &
    sleep 1
    echo "✅ TUIC 已启动"
}

# ===================== 主逻辑 =====================
main() {
    check_dependencies
    read_port "$@"

    # 生成 UUID 和密码
    TUIC_UUID="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
    TUIC_PASSWORD="$(openssl rand -hex 16)"
    echo "🔑 UUID: $TUIC_UUID"
    echo "🔑 密码: $TUIC_PASSWORD"
    echo "🎯 SNI: $MASQ_DOMAIN"

    generate_cert
    download_tuic
    generate_config

    SERVER_IP=$(get_server_ip)
    generate_link "$SERVER_IP"
    start_service

    echo "🎉 TUIC 部署完成！"
    echo "📄 配置文件: $SERVER_TOML"
    echo "🔗 链接文件: $LINK_TXT"
    echo "⚙️ 启动脚本目录: $TUIC_DIR"
}

main "$@"
