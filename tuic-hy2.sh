#!/bin/bash
# ==========================================
# 🚀 TUIC 通用一键安装脚本 (适配 Alpine / Debian / Ubuntu)
# 作者: eishare 2025
# ==========================================

set -e

PORT=${1:-443}
WORK_DIR="/root/tuic"
TUIC_BIN="tuic-server"
CONFIG_FILE="$WORK_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/tuic.service"

# 🧠 检测系统类型
detect_os() {
    if [ -f /etc/alpine-release ]; then
        OS="alpine"
    elif [ -f /etc/debian_version ]; then
        OS="debian"
    elif grep -qi ubuntu /etc/os-release; then
        OS="ubuntu"
    else
        echo "❌ 不支持的系统，请使用 Debian/Ubuntu/Alpine。"
        exit 1
    fi
}

# 🔧 安装依赖
install_deps() {
    echo "🔧 正在安装依赖..."
    if [ "$OS" = "alpine" ]; then
        apk add --no-cache curl bash openssl coreutils procps
    else
        apt update -y && apt install -y curl bash openssl coreutils procps
    fi
    echo "✅ 依赖安装完成"
}

# 📂 创建持久化目录
setup_dir() {
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
}

# 🔑 生成 UUID、密码和证书
gen_certs() {
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PASS=$(openssl rand -hex 16)
    openssl ecparam -genkey -name prime256v1 -out tuic.key
    openssl req -new -x509 -days 3650 -key tuic.key -out tuic.crt -subj "/CN=tuic"
    echo "✅ 证书与密钥生成完成"
}

# ⬇️ 下载 TUIC 二进制文件
install_tuic() {
    echo "⬇️ 下载 TUIC..."
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
    echo "✅ TUIC 下载完成"
}

# ⚙️ 生成配置文件
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

# 🔗 输出分享信息
show_info() {
    LINK="tuic://${UUID}:${PASS}@your_domain_or_ip:${PORT}?congestion_control=bbr#TUIC-${PORT}"
    echo "$LINK" > "$WORK_DIR/tuic_link.txt"
    echo "✅ 节点链接已写入：$WORK_DIR/tuic_link.txt"
}

# 🧠 创建 systemd 或守护进程
create_service() {
    if [ "$OS" = "alpine" ]; then
        echo "🧩 Alpine 环境检测到，使用后台守护进程方式..."
        cat > "$WORK_DIR/start.sh" <<EOF
#!/bin/bash
cd $WORK_DIR
nohup $WORK_DIR/$TUIC_BIN -c $CONFIG_FILE > $WORK_DIR/tuic.log 2>&1 &
echo \$! > $WORK_DIR/tuic.pid
EOF
        chmod +x "$WORK_DIR/start.sh"

        cat > "$WORK_DIR/stop.sh" <<EOF
#!/bin/bash
if [ -f $WORK_DIR/tuic.pid ]; then
    kill \$(cat $WORK_DIR/tuic.pid) && rm -f $WORK_DIR/tuic.pid
    echo "✅ TUIC 已停止"
else
    echo "⚠️ 未检测到运行中的 TUIC"
fi
EOF
        chmod +x "$WORK_DIR/stop.sh"
        echo "✅ 已创建 start.sh / stop.sh，可手动启动或停止 TUIC"
    else
        echo "🧠 创建 systemd 服务..."
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
        echo "✅ TUIC 服务已启动并设置开机自启"
    fi
}

# 🚀 主流程
main() {
    echo "🔍 检测系统..."
    detect_os
    install_deps
    setup_dir
    gen_certs
    install_tuic
    create_config
    show_info
    create_service
    echo "🎉 TUIC 部署完成！"
    echo "📁 配置目录: $WORK_DIR"
    echo "🔗 节点链接: $(cat $WORK_DIR/tuic_link.txt)"
}

main
