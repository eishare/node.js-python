#!/usr/bin/env bash
# TUIC v5 over QUIC 自动部署脚本 - 修正版
# 支持端口参数 / systemd / 自签证书 / 卸载
set -e

TUIC_PORT="${1:-0}"   # 默认端口，可通过命令行传入
CERT_FILE="/etc/tuic-cert.pem"
KEY_FILE="/etc/tuic-key.pem"
CONFIG_FILE="/etc/tuic-server.toml"
TUIC_BIN="/usr/local/bin/tuic-server"
SERVICE_NAME="tuic-server"

# ===================== 系统检测 =====================
detect_os() {
    OS_NAME=$(awk -F= '/^ID=/{print $2}' /etc/os-release | tr -d '"')
    ARCH=$(uname -m)
    if [[ "$ARCH" != "x86_64" ]]; then
        echo "❌ 仅支持 x86_64 架构"
        exit 1
    fi
    echo "检测系统: $OS_NAME $ARCH"
}

# ===================== 下载 TUIC =====================
download_tuic() {
    if [[ -x "$TUIC_BIN" ]]; then
        echo "✅ TUIC 已安装: $TUIC_BIN"
        return
    fi

    echo "⏳ 下载 TUIC..."

    case "$OS_NAME" in
        debian|ubuntu|centos)
            TUIC_URL="https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-x86_64-linux"
            ;;
        alpine)
            echo "⚠️ Alpine 系统需要 musl 编译版本或自行编译，脚本暂不支持直接运行"
            exit 1
            ;;
        *)
            echo "❌ 系统不支持: $OS_NAME"
            exit 1
            ;;
    esac

    curl -fL -o "$TUIC_BIN" "$TUIC_URL"
    chmod +x "$TUIC_BIN"
    echo "✅ TUIC 下载完成"
}

# ===================== 证书生成 =====================
generate_cert() {
    if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        echo "✅ 检测到证书，跳过生成"
        return
    fi
    echo "🔐 生成自签证书 (www.bing.com)..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=www.bing.com" -days 365
    chmod 600 "$KEY_FILE" 644 "$CERT_FILE"
    echo "✅ 证书生成完成"
}

# ===================== 配置生成 =====================
generate_config() {
    if [[ "$TUIC_PORT" -eq 0 ]]; then
        read -rp "请输入 TUIC 端口 (1024-65535): " TUIC_PORT
    fi
    cat > "$CONFIG_FILE" <<EOF
log_level = "off"
server = "0.0.0.0:${TUIC_PORT}"

[users]
$(uuidgen) = "$(openssl rand -hex 16)"

[tls]
self_sign = false
certificate = "$CERT_FILE"
private_key = "$KEY_FILE"
alpn = ["h3"]

[restful]
addr = "127.0.0.1:${TUIC_PORT}"
secret = "$(openssl rand -hex 16)"
maximum_clients_per_user = 999999999

[quic]
initial_mtu = 1500
min_mtu = 1200
send_window = 33554432
receive_window = 16777216
max_idle_time = "20s"

[quic.congestion_control]
controller = "bbr"
initial_window = 4194304
EOF
    echo "✅ 配置生成完成: $CONFIG_FILE"
}

# ===================== systemd =====================
setup_systemd() {
    cat > "/etc/systemd/system/$SERVICE_NAME.service" <<EOF
[Unit]
Description=TUIC v5 QUIC Server
After=network.target

[Service]
ExecStart=$TUIC_BIN -c $CONFIG_FILE
Restart=always
RestartSec=5
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"
    echo "✅ TUIC 服务已启动并加入自启: $SERVICE_NAME"
}

# ===================== 卸载 =====================
uninstall_tuic() {
    systemctl stop "$SERVICE_NAME" || true
    systemctl disable "$SERVICE_NAME" || true
    rm -f "$TUIC_BIN" "$CONFIG_FILE" "$CERT_FILE" "$KEY_FILE"
    rm -f "/etc/systemd/system/$SERVICE_NAME.service"
    systemctl daemon-reload
    echo "✅ TUIC 已卸载"
    exit 0
}

# ===================== 主流程 =====================
main() {
    detect_os

    if [[ "${1:-}" == "uninstall" ]]; then
        uninstall_tuic
    fi

    download_tuic
    generate_cert
    generate_config
    setup_systemd
}

main "$@"
