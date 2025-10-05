#!/usr/bin/env bash
# TUIC 一键部署脚本 - 支持 Alpine / Ubuntu / Debian / CentOS
# 自动检测架构 + systemd/OpenRC + 自签证书 + 端口跳跃

set -e

# ==== 用户可选配置 ====
TUIC_VERSION="v1.0.0"
CERT_DOMAIN="www.bing.com"
PASSWORD="P$(date +%s)"
# =======================

# 参数: 固定端口或范围
BASE_PORT=${1:-10000}
PORT_RANGE=${2:-0}

# 随机端口逻辑
if [ "$PORT_RANGE" -gt 0 ]; then
  RANDOM_PORT=$((BASE_PORT + RANDOM % PORT_RANGE))
else
  RANDOM_PORT=$BASE_PORT
fi

# 自动检测架构
detect_arch() {
  local arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    *) echo "unsupported";;
  esac
}
ARCH=$(detect_arch)
if [ "$ARCH" = "unsupported" ]; then
  echo "❌ 不支持的架构: $(uname -m)"
  exit 1
fi

# 下载 TUIC 二进制
download_tuic() {
  local url="https://github.com/EAimTY/tuic/releases/download/${TUIC_VERSION}/tuic-server-${ARCH}-unknown-linux-musl"
  echo "⏳ 下载 TUIC: $url"
  curl -L --retry 3 -o /usr/local/bin/tuic-server "$url" || {
    echo "❌ 下载失败，请检查版本或架构"
    exit 1
  }
  chmod +x /usr/local/bin/tuic-server
  echo "✅ TUIC 已安装: /usr/local/bin/tuic-server"
}

# 生成证书
generate_cert() {
  if [ -f /etc/tuic/cert.pem ] && [ -f /etc/tuic/key.pem ]; then
    echo "🔐 已检测到证书，跳过生成"
    return
  fi
  mkdir -p /etc/tuic
  echo "🔐 生成自签名证书 ($CERT_DOMAIN)..."
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 3650 -keyout /etc/tuic/key.pem -out /etc/tuic/cert.pem -subj "/CN=$CERT_DOMAIN"
  echo "✅ 证书生成成功"
}

# 写配置文件
write_config() {
  cat > /etc/tuic/config.json <<EOF
{
  "server": "[::]:$RANDOM_PORT",
  "users": {
    "user": "$PASSWORD"
  },
  "certificate": "/etc/tuic/cert.pem",
  "private_key": "/etc/tuic/key.pem",
  "congestion_control": "bbr",
  "alpn": ["h3"],
  "udp_relay_mode": "native"
}
EOF
  echo "✅ TUIC 配置已生成: 端口 $RANDOM_PORT"
}

# 创建 systemd / openrc 服务
create_service() {
  if command -v systemctl >/dev/null 2>&1; then
    cat > /etc/systemd/system/tuic-server.service <<EOF
[Unit]
Description=TUIC Server
After=network.target

[Service]
ExecStart=/usr/local/bin/tuic-server -c /etc/tuic/config.json
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable tuic-server
    systemctl restart tuic-server
  elif command -v rc-update >/dev/null 2>&1; then
    cat > /etc/init.d/tuic-server <<'EOF'
#!/sbin/openrc-run
description="TUIC server"
command="/usr/local/bin/tuic-server"
command_args="-c /etc/tuic/config.json"
pidfile="/run/tuic-server.pid"
depend() {
  need net
}
EOF
    chmod +x /etc/init.d/tuic-server
    rc-update add tuic-server default
    rc-service tuic-server restart
  else
    echo "⚠️ 未检测到 systemd 或 OpenRC，请手动运行："
    echo "/usr/local/bin/tuic-server -c /etc/tuic/config.json"
  fi
}

main() {
  download_tuic
  generate_cert
  write_config
  create_service
  echo "🎉 TUIC 部署完成"
  echo "节点：tuic://${PASSWORD}@$(curl -s ipv4.ip.sb):$RANDOM_PORT"
}

main
