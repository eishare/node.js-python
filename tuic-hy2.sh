#!/bin/bash
# ===================================================
# 极度精简 Tuic 一键安装脚本 (x86_64 Linux)
# 支持 V4 / V5
# ===================================================

[[ $EUID -ne 0 ]] && echo "请以 root 用户运行" && exit 1

# 颜色
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; PLAIN="\033[0m"
cecho(){ echo -e "${!1}$2${PLAIN}"; }

# 系统依赖
[[ -z $(type -P curl) ]] && (apt-get update; apt-get install -y curl wget sudo)

ARCH=$(uname -m)
[[ $ARCH != "x86_64" ]] && cecho RED "仅支持 x86_64 Linux" && exit 1

IP=$(curl -4s ip.sb || curl -6s ip.sb)

TUIC_BIN="/usr/local/bin/tuic"
TUIC_DIR="/etc/tuic"
CLIENT_DIR="/root/tuic"
mkdir -p $TUIC_DIR $CLIENT_DIR

# ==================== 函数 ====================

install_v5(){
    # 下载 TUIC V5
    wget -qO $TUIC_BIN "https://github.com/EAimTY/tuic/releases/download/v1.0.0/tuic-server-x86_64-unknown-linux-musl"
    chmod +x $TUIC_BIN

    # 证书
    CERT="$CLIENT_DIR/cert.crt"; KEY="$CLIENT_DIR/private.key"
    if [[ ! -f $CERT || ! -f $KEY ]]; then
        openssl ecparam -genkey -name prime256v1 -out $KEY
        openssl req -new -x509 -days 36500 -key $KEY -out $CERT -subj "/CN=www.bing.com"
    fi

    # 端口/UUID/密码
    read -p "设置Tuic端口 [回车随机2000-65535]：" PORT
    PORT=${PORT:-$(shuf -i 2000-65535 -n 1)}
    read -p "设置Tuic UUID [回车随机]：" UUID
    UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
    read -p "设置Tuic密码 [回车随机]：" PASSWD
    PASSWD=${PASSWD:-$(date +%s%N | md5sum | cut -c1-8)}

    # 配置文件
    cat > $TUIC_DIR/tuic.json <<EOF
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

    cat > $CLIENT_DIR/tuic-client.json <<EOF
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

    echo "tuic://$UUID:$PASSWD@$IP:$PORT?congestion_control=bbr&udp_relay_mode=quic&alpn=h3#tuicv5" > $CLIENT_DIR/url.txt

    systemd_service
}

systemd_service(){
    cat > /etc/systemd/system/tuic.service <<EOF
[Unit]
Description=Tuic Service
After=network.target
[Service]
ExecStart=$TUIC_BIN -c $TUIC_DIR/tuic.json
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

    if systemctl is-active --quiet tuic; then
        cecho GREEN "Tuic 服务启动成功"
    else
        cecho RED "Tuic 服务启动失败，请 systemctl status tuic 查看"
    fi
}

uninstall_tuic(){
    systemctl stop tuic
    systemctl disable tuic
    rm -rf $TUIC_BIN $TUIC_DIR $CLIENT_DIR /etc/systemd/system/tuic.service
    systemctl daemon-reload
    cecho GREEN "Tuic 已彻底卸载完成"
}

change_port(){
    OLD_PORT=$(jq '.server' $TUIC_DIR/tuic.json | awk -F ':' '{print $4}' | tr -d '"')
    read -p "设置新端口 [1-65535]：" PORT
    PORT=${PORT:-$((RANDOM+2000))}
    sed -i "s/$OLD_PORT/$PORT/g" $TUIC_DIR/tuic.json $CLIENT_DIR/tuic-client.json $CLIENT_DIR/url.txt
    systemctl restart tuic
    cecho GREEN "端口修改成功为 $PORT"
}

change_uuid(){
    OLD_UUID=$(jq '.users | keys[]' $TUIC_DIR/tuic.json | tr -d '"')
    read -p "设置新UUID [回车随机]：" UUID
    UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
    sed -i "s/$OLD_UUID/$UUID/g" $TUIC_DIR/tuic.json $CLIENT_DIR/tuic-client.json $CLIENT_DIR/url.txt
    systemctl restart tuic
    cecho GREEN "UUID修改成功为 $UUID"
}

change_passwd(){
    OLD_PASS=$(jq '.users[]' $TUIC_DIR/tuic.json | tr -d '"')
    read -p "设置新密码 [回车随机]：" PASSWD
    PASSWD=${PASSWD:-$(date +%s%N | md5sum | cut -c1-8)}
    sed -i "s/$OLD_PASS/$PASSWD/g" $TUIC_DIR/tuic.json $CLIENT_DIR/tuic-client.json $CLIENT_DIR/url.txt
    systemctl restart tuic
    cecho GREEN "密码修改成功为 $PASSWD"
}

show_conf(){
    cecho YELLOW "客户端配置文件：$CLIENT_DIR/tuic-client.json"
    cat $CLIENT_DIR/tuic-client.json
    cecho YELLOW "Tuic 链接：$CLIENT_DIR/url.txt"
    cat $CLIENT_DIR/url.txt
}

tuic_switch(){
    echo -e "1. 启动\n2. 停止\n3. 重启"
    read -p "选择操作：" OP
    case $OP in
        1) systemctl start tuic ;;
        2) systemctl stop tuic ;;
        3) systemctl restart tuic ;;
        *) exit 1 ;;
    esac
}

# ==================== 菜单 ====================
while :; do
clear
echo "================ Tuic 极简安装脚本 ================"
echo -e "1. 安装 Tuic V5\n2. 卸载 Tuic\n3. 启动/停止/重启 Tuic\n4. 修改端口\n5. 修改UUID\n6. 修改密码\n7. 显示配置\n0. 退出"
read -p "选择操作 [0-7]：" CHOICE
case $CHOICE in
    1) install_v5 ;;
    2) uninstall_tuic ;;
    3) tuic_switch ;;
    4) change_port ;;
    5) change_uuid ;;
    6) change_passwd ;;
    7) show_conf ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
esac
read -p "按回车返回菜单..."
done
