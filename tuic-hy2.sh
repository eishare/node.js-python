#!/bin/bash
# ==========================================
# 🌐 通用 TUIC 安装脚本（含公网IP自动识别 + SNI 修复）
# 适配 Alpine / Debian / Ubuntu / Claw Cloud 容器
# 作者: eishare 2025
# ==========================================

set -e
PORT=${1:-443}
WORK_DIR="/root/tuic"
TUIC_BIN="tuic-server"
CONFIG_FILE="$WORK_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/tuic.service"

# 检测系统
detect_os() {
    if [ -f /etc/alpine-release ]; then
        OS="alpine"
    elif grep -qi ubuntu /etc/os-release; then
        OS="ubuntu"
    elif grep -qi debian /etc/os-release; then
        OS="debian"
    else
        echo "❌ 不支持的系统类型"; exit 1
    fi
}

# 安装依赖
install_deps() {
    echo "🔧 安装依赖中..."
    if [ "$OS" = "alpine" ]; then
        apk add --no-cache curl bash openssl coreutils procps iproute2
    else
        apt update -y && apt install -y curl bash openssl coreutils procps iproute2
    fi
    echo "✅ 依赖安装完成"
}

# 获取公网 IP
get_public_ip() {
    IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me || echo "127.0.0.1")
    echo "🌐 检测到公网 IP: $IP"
}

# 生成证书、UUID
gen_certs() {
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PASS=$(openssl rand -hex 16)
    openssl ecparam -genkey -name prime256v1 -out tuic.key
    openssl req -new -x509 -days 3650 -key tuic.key -out tuic.crt -subj "/CN=$IP"
}

# 下载 TUIC
install_tuic() {
    cd "$WORK_DIR"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCH="x86_64" ;;
        aarch64) ARCH="aarch64" ;;
        armv7l) ARCH="armv7" ;;
        *) echo "❌ 不支持的架构: $ARCH"; exit 1 ;;
    esac
    URL="https://github.com/Itsusinn/tuic/releases/download/v1.5.2/tuic-server-${ARCH}-linux"
    curl -L -o "$TUIC_BIN" "$URL"
    chmod +x "$TUIC_BIN"
}

# 写入配置文件
create_config() {
    cat > "$CONFIG_FILE" <<EOF
{
    "server": "0.0.0.0:${PORT}",
    "users": {
        "${UUID}": "${PASS}"
    },
    "certificate": "${WORK_DIR}/tuic.crt",
    "private_key": "${WORK_DIR}/tuic.key",
    "congestion_control": "bbr",
    "alpn": ["h3"],
    "log_level": "info"
}
EOF
    echo "✅ 配置文件生成完成"
}

# 输出节点信息
show_info() {
    LINK="tuic://${UUID}:${PASS}@${IP}:${PORT}?congestion_control=bbr&sni=${IP}#TUIC-${PORT}"
    echo "$LINK" > "$WORK_DIR/tuic_link.txt"
    echo "✅ 节点链接写入 $WORK_DIR/tuic_link.txt"
    echo "🔗 $LINK"
}

# 创建启动脚本 / systemd
create_service() {
    if [ "$OS" = "alpine" ]; then
        cat > "$WORK_DIR/start.sh" <<EOF
#!/bin/bash
cd $WORK_DIR
nohup $WORK_DIR/$TUIC_BIN -c $CONFIG_FILE > $WORK_DIR/tuic.log 2>&1 &
echo \$! > $WORK_DIR/tuic.pid
EOF
        chmod +x "$WORK_DIR/start.sh"
        echo "✅ 可执行：bash /root/tuic/start.sh 启动 TUIC"
    else
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=TUIC Server
After=network.target

[Service]
ExecStart=$WORK_DIR/$TUIC_BIN -c $CONFIG_FILE
WorkingDirectory=$WORK_DIR
Restart=always
RestartSec=3
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable tuic
        systemctl restart tuic
        echo "✅ 已创建 systemd 服务 tuic 并自动启动"
    fi
}

# 主逻辑
main() {
    detect_os
    install_deps
    get_public_ip
    gen_certs
    install_tuic
    create_config
    create_service
    show_info
    echo "🎉 TUIC 部署完成"
    echo "📁 目录: $WORK_DIR"
}

main
