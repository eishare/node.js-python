#!/bin/bash
# TUIC 一键部署 + 守护 + 自启动 + 卸载
# 版本：v2025.10.09
# 作者：eishare 定制 for 爪云环境

set -e
PORT=${1:-443}
WORK_DIR="/root/tuic"
TUIC_BIN="$WORK_DIR/tuic-server"
CONFIG_FILE="$WORK_DIR/server.toml"
LINK_FILE="$WORK_DIR/tuic_link.txt"
GUARD_SCRIPT="$WORK_DIR/tuic-guard.sh"
SYSTEMD_SERVICE="/etc/systemd/system/tuic.service"
VERSION="v1.5.2"
TUIC_URL="https://github.com/Itsusinn/tuic/releases/download/${VERSION}/tuic-server-x86_64-linux"

uninstall_tuic() {
    echo "🧹 正在卸载 TUIC..."
    systemctl stop tuic >/dev/null 2>&1 || true
    systemctl disable tuic >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_SERVICE"
    rm -rf "$WORK_DIR"
    echo "✅ TUIC 已卸载完成"
    exit 0
}

[[ "$1" == "uninstall" ]] && uninstall_tuic

echo "🔧 检查系统依赖..."
if command -v apk >/dev/null 2>&1; then
    apk add --no-cache bash curl openssl coreutils grep sed procps
elif command -v apt >/dev/null 2>&1; then
    apt update -y && apt install -y bash curl openssl coreutils grep sed procps
elif command -v yum >/dev/null 2>&1; then
    yum install -y bash curl openssl coreutils grep sed procps-ng
else
    echo "❌ 不支持的系统，请手动安装 curl bash openssl 等基础依赖"
    exit 1
fi
echo "✅ 依赖安装完成"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "🔑 生成随机 UUID 和密码..."
UUID=$(cat /proc/sys/kernel/random/uuid)
PASS=$(openssl rand -hex 16)
echo "UUID: $UUID"
echo "PASS: $PASS"

echo "🔐 生成自签 ECDSA-P256 证书..."
openssl ecparam -genkey -name prime256v1 -out private.key
openssl req -new -x509 -days 3650 -key private.key -out cert.pem -subj "/CN=www.bing.com"
echo "✅ 证书生成完成"

echo "⬇️ 下载 TUIC..."
curl -L -o "$TUIC_BIN" "$TUIC_URL"
chmod +x "$TUIC_BIN"
echo "✅ TUIC 下载完成"

echo "⚙️ 生成配置文件..."
cat > "$CONFIG_FILE" <<EOF
[server]
port = ${PORT}
token = ["${PASS}"]
certificate = "${WORK_DIR}/cert.pem"
private_key = "${WORK_DIR}/private.key"
[log]
level = "warn"
EOF
echo "✅ 配置文件生成完成"

echo "🔗 生成节点分享链接..."
SERVER_IP=$(curl -s ipv4.ip.sb || curl -s ipinfo.io/ip)
echo "tuic://${UUID}:${PASS}@${SERVER_IP}:${PORT}?congestion_control=bbr&alpn=h3&udp_relay_mode=native&reduce_rtt=1#TUIC-${SERVER_IP}" > "$LINK_FILE"
echo "✅ 节点链接写入 $LINK_FILE"

echo "🛡️ 创建守护进程脚本..."
cat > "$GUARD_SCRIPT" <<EOF
#!/bin/bash
while true; do
  if ! pgrep -f "tuic-server" >/dev/null; then
    echo "\$(date) ⚠️ TUIC 未运行，正在重启..." >> /root/tuic/tuic.log
    nohup $TUIC_BIN -c $CONFIG_FILE >> /root/tuic/tuic.log 2>&1 &
  fi
  sleep 10
done
EOF
chmod +x "$GUARD_SCRIPT"
echo "✅ 守护进程创建完成"

echo "🧠 创建 systemd 服务 (支持自动启动)..."
cat > "$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=TUIC Server
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c "nohup ${TUIC_BIN} -c ${CONFIG_FILE} >> ${WORK_DIR}/tuic.log 2>&1 & /bin/bash ${GUARD_SCRIPT}"
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable tuic
systemctl start tuic
echo "✅ systemd 服务已创建并启动"

echo "🎉 TUIC 部署完成"
echo "📄 配置文件: $CONFIG_FILE"
echo "🔗 节点链接: $LINK_FILE"
echo "📜 日志文件: $WORK_DIR/tuic.log"
echo "💡 卸载命令: bash tuic.sh uninstall"
