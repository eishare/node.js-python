#!/bin/bash
# ===================================================
# 极度精简 Tuic V5 一键安装脚本 (x86_64 Linux)
# ===================================================

# 检测root
[[ $EUID -ne 0 ]] && echo "请以 root 用户运行" && exit 1

# 设置颜色
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; PLAIN="\033[0m"
cecho(){ echo -e "${!1}$2${PLAIN}"; }

# 系统与依赖
[[ -z $(type -P curl) ]] && (apt-get update; apt-get install -y curl wget sudo)
ARCH=$(uname -m)
[[ $ARCH != "x86_64" ]] && cecho RED "仅支持 x86_64 Linux" && exit 1

# 获取公网IP
IP=$(curl -4s ip.sb || curl -6s ip.sb)

# ==================== 证书 ====================
CERT_DIR="/root/bing"
mkdir -p $CERT_DIR
CERT="$CERT_DIR/cert.crt"; KEY="$CERT_DIR/private.key"
if [[ ! -f $CERT || ! -f $KEY ]]; then
  openssl ecparam -genkey -name prime256v1 -out $KEY
  openssl req -new -x509 -days 36500 -key $KEY -out $CERT -subj "/CN=www.bing.com"
fi

# ==================== 安装Tuic ====================
TUIC_BIN="/usr/local/bin/tuic"
wget -qO $TUIC_BIN "https://github.com/EAimTY/tuic/releases/download/v1.0.0/tuic-server-x86_64-unknown-linux-musl"
chmod +x $TUIC_BIN

# ==================== 配置 ====================
read -p "设置Tuic端口 [回车随机2000-65535]：" PORT
PORT=${PORT:-$(shuf -i 2000-65535 -n 1)}
read -p "设置Tuic UUID [回车随机]：" UUID
UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
read -p "设置Tuic密码 [回车随机]：" PASSWD
PASSWD=${PASSWD:-$(date +%s%N | md5sum | cut -c1-8)}

mkdir -p /etc/tuic /root/tuic

cat > /etc/tuic/tuic.json <<EOF
{
  "server": "[::]:$PORT",
  "users": { "$UUID": "$PASSWD" },
  "certificate": "$CERT",
  "private_key": "$KEY",
  "congestion_control": "bbr",
  "alpn": ["h3"],
  "log_level": "warn"
}
EOF

cat > /root/tuic/tuic-client.json <<EOF
{
  "relay": {
    "server": "$IP:$PORT",
    "uuid": "$UUID",
    "password": "$PASSWD",
    "ip": "$IP",
    "congestion_control": "bbr",
    "alpn": ["h3"]
  },
  "local": { "server": "127.0.0.1:6080" },
  "log_level": "warn"
}
EOF

cat > /root/tuic/url.txt <<EOF
tuic://$UUID:$PASSWD@$IP:$PORT?congestion_control=bbr&udp_relay_mode=quic&alpn=h3#tuicv5
EOF

# ==================== systemd ====================
cat > /etc/systemd/system/tuic.service <<EOF
[Unit]
Description=Tuic Service
After=network.target

[Service]
ExecStart=$TUIC_BIN -c /etc/tuic/tuic.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tuic
systemctl restart tuic

# ==================== 状态 ====================
if systemctl is-active --quiet tuic; then
  cecho GREEN "Tuic 启动成功，端口:$PORT"
  cecho GREEN "客户端配置已保存到 /root/tuic/tuic-client.json"
  cecho GREEN "Tuic链接已保存到 /root/tuic/url.txt"
else
  cecho RED "Tuic 启动失败，请 systemctl status tuic 查看"
fi

# ==================== 卸载 ====================
unset TUIC_UNINSTALL
read -p "是否需要卸载Tuic? [y/N]：" TUIC_UNINSTALL
[[ $TUIC_UNINSTALL == [yY] ]] && {
  systemctl stop tuic
  systemctl disable tuic
  rm -rf /etc/tuic /root/tuic $TUIC_BIN /etc/systemd/system/tuic.service
  systemctl daemon-reload
  cecho GREEN "Tuic已卸载完成"
}
