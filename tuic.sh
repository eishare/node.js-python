#!/bin/bash
set -e

# ========= TUIC v5 一键部署增强版 ========= #
# 作者: Eishare（优化 by ChatGPT）
# 功能: 自动部署 TUIC Server + 抗 QoS 优化 + 智能 BBR 检测
# ======================================== #

# ------------------------------
# 🧩 系统检测与准备
# ------------------------------
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "⚠️ 请使用 root 用户运行此脚本"
    exit 1
  fi
}

install_deps() {
  echo "📦 安装依赖..."
  if command -v apt >/dev/null 2>&1; then
    apt update -y && apt install -y curl wget jq tar
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl wget jq tar
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl wget jq tar
  fi
}

# ------------------------------
# ⚙️ 启用 BBR（智能检测版）
# ------------------------------
enable_bbr() {
  echo "⚙️ 检查并启用 BBR 拥塞控制..."
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    echo "✅ 已启用 BBR"
  else
    if modprobe tcp_bbr 2>/dev/null; then
      echo "tcp_bbr" >> /etc/modules-load.d/modules.conf 2>/dev/null || true
      sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
      sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
      echo "✅ 成功启用 BBR"
    else
      echo "⚠️ 当前系统内核不支持 BBR，使用 CUBIC 模式继续运行"
    fi
  fi
}

# ------------------------------
# 🌐 下载 TUIC 二进制文件
# ------------------------------
install_tuic() {
  echo "⬇️ 安装 TUIC v5 服务端..."
  LATEST_URL=$(curl -s https://api.github.com/repos/EAimTY/tuic/releases/latest | jq -r '.assets[] | select(.name | test("x86_64-unknown-linux-gnu")) | .browser_download_url')
  mkdir -p /usr/local/bin
  wget -qO /usr/local/bin/tuic-server "$LATEST_URL"
  chmod +x /usr/local/bin/tuic-server
}

# ------------------------------
# ⚙️ 生成 TUIC 配置文件
# ------------------------------
generate_config() {
  mkdir -p /etc/tuic
  TUIC_PORT=${TUIC_PORT:-$((RANDOM % 55535 + 10000))}
  UUID=$(cat /proc/sys/kernel/random/uuid)
  PASSWORD=$(openssl rand -base64 12)
  MASQ_DOMAIN=${MASQ_DOMAIN:-"www.bing.com"}

  echo "⚙️ 正在生成 TUIC v5 配置文件..."
  cat > /etc/tuic/tuic.json <<EOF
{
  "server": "[::]:${TUIC_PORT}",
  "users": {
    "${UUID}": "${PASSWORD}"
  },
  "certificate": "/etc/ssl/certs/ssl-cert-snakeoil.pem",
  "private_key": "/etc/ssl/private/ssl-cert-snakeoil.key",
  "congestion_control": "bbr",
  "alpn": ["h3"],
  "auth_timeout": "3s",
  "zero_rtt_handshake": true,
  "heartbeat_interval": "15s",
  "max_idle_time": "600s",
  "disable_sni": false,
  "server_name": "${MASQ_DOMAIN}",
  "log_level": "warn",
  "log_file": "/etc/tuic/tuic.log"
}
EOF

  echo "✅ TUIC 配置生成完成"
}

# ------------------------------
# 🔄 生成 Systemd 服务
# ------------------------------
generate_service() {
  cat > /etc/systemd/system/tuic.service <<EOF
[Unit]
Description=TUIC v5 Server
After=network.target

[Service]
ExecStart=/usr/local/bin/tuic-server -c /etc/tuic/tuic.json
Restart=always
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reexec
  systemctl daemon-reload
  systemctl enable --now tuic.service
}

# ------------------------------
# 📜 输出连接信息
# ------------------------------
show_info() {
  echo
  echo "🎉 TUIC v5 部署完成！以下是连接信息："
  echo "--------------------------------------------"
  echo "协议: tuic"
  echo "地址: $(curl -s ifconfig.me)"
  echo "端口: ${TUIC_PORT}"
  echo "UUID: ${UUID}"
  echo "密码: ${PASSWORD}"
  echo "SNI: ${MASQ_DOMAIN}"
  echo "ALPN: h3"
  echo "0-RTT: 已启用"
  echo "UDP: 原生中继"
  echo "--------------------------------------------"
  echo "示例客户端 URL："
  echo "tuic://${UUID}:${PASSWORD}@$(curl -s ifconfig.me):${TUIC_PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1&disable_sni=0&zero_rtt_handshake=1#TUICv5"
  echo "--------------------------------------------"
  echo "📄 配置文件路径: /etc/tuic/tuic.json"
  echo "日志文件路径: /etc/tuic/tuic.log"
  echo
}

# ------------------------------
# 🚀 主执行流程
# ------------------------------
main() {
  check_root
  install_deps
  enable_bbr
  install_tuic
  generate_config
  generate_service
  show_info
}

main
