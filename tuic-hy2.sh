#!/bin/bash
set -e
PORT=${1:-443}
WORK_DIR="/root/tuic"
TUIC_BIN="$WORK_DIR/tuic-server"
CONFIG_FILE="$WORK_DIR/config.json"
LOG_FILE="$WORK_DIR/tuic.log"

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

install_deps() {
    echo "🔧 检查依赖..."
    if [ "$OS" = "alpine" ]; then
        apk add --no-cache bash curl openssl coreutils procps iproute2
    else
        apt update -y && apt install -y bash curl openssl coreutils procps iproute2
    fi
}

get_public_ip() {
    IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me || echo "127.0.0.1")
}

gen_certs() {
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PASS=$(openssl rand -hex 16)
    openssl ecparam -genkey -name prime256v1 -out tuic.key
    openssl req -new -x509 -days 3650 -key tuic.key -out tuic.crt -subj "/CN=$IP"
}

install_tuic() {
    cd "$WORK_DIR"
    ARCH=$(uname -m)
    [ "$ARCH" = "x86_64" ] && ARCH="x86_64"
    URL="https://github.com/Itsusinn/tuic/releases/download/v1.5.2/tuic-server-${ARCH}-linux"
    curl -L -o "$TUIC_BIN" "$URL"
    chmod +x "$TUIC_BIN"
}

create_config() {
    cat > "$CONFIG_FILE" <<EOF
{
    "server": "0.0.0.0:${PORT}",
    "users": { "${UUID}": "${PASS}" },
    "certificate": "${WORK_DIR}/tuic.crt",
    "private_key": "${WORK_DIR}/tuic.key",
    "congestion_control": "bbr",
    "alpn": ["h3"],
    "log_level": "info"
}
EOF
}

start_tuic() {
    echo "🚀 启动 TUIC..."
    if command -v systemctl >/dev/null 2>&1; then
        cat > /etc/systemd/system/tuic.service <<EOF
[Unit]
Description=TUIC Server
After=network.target
[Service]
ExecStart=$TUIC_BIN -c $CONFIG_FILE
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable tuic
        systemctl restart tuic
    else
        # 无 systemd，使用 nohup 后台守护
        nohup bash -c "
        while true; do
            $TUIC_BIN -c $CONFIG_FILE >> $LOG_FILE 2>&1
            echo 'TUIC 已退出，5 秒后重启...' >> $LOG_FILE
            sleep 5
        done
        " >/dev/null 2>&1 &
        echo "✅ TUIC 后台守护启动成功 (nohup 模式)"
    fi
}

show_info() {
    LINK="tuic://${UUID}:${PASS}@${IP}:${PORT}?congestion_control=bbr&sni=${IP}#TUIC-${PORT}"
    echo "$LINK" > "$WORK_DIR/tuic_link.txt"
    echo "🔗 $LINK"
}

main() {
    detect_os
    install_deps
    get_public_ip
    gen_certs
    install_tuic
    create_config
    start_tuic
    show_info
    echo "🎉 TUIC 部署完成"
}

main
