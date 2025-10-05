#!/bin/bash
# TUIC v5 over QUIC 自动部署脚本（支持 Pterodactyl SERVER_PORT、自启动）
set -euo pipefail
IFS=$'\n\t'

MASQ_DOMAINS=(
  "www.microsoft.com"
  "www.cloudflare.com"
  "www.bing.com"
  "www.apple.com"
  "www.amazon.com"
  "www.wikipedia.org"
  "cdnjs.cloudflare.com"
  "cdn.jsdelivr.net"
  "static.cloudflareinsights.com"
  "www.speedtest.net"
)
MASQ_DOMAIN=${MASQ_DOMAINS[$RANDOM % ${#MASQ_DOMAINS[@]}]}

SERVER_TOML="/etc/tuic/server.toml"
CERT_PEM="/etc/tuic/tuic-cert.pem"
KEY_PEM="/etc/tuic/tuic-key.pem"
LINK_TXT="/etc/tuic/tuic_link.txt"
TUIC_BIN="/usr/local/bin/tuic-server"

# ===================== 输入端口或读取环境变量 =====================
read_port() {
  # 1️⃣ 优先使用命令行参数
  if [[ -n "${1:-}" ]]; then
    TUIC_PORT="$1"
    echo "✅ 从命令行参数读取 TUIC(QUIC) 端口: $TUIC_PORT"
    return
  fi

  # 2️⃣ 检查环境变量 SERVER_PORT（适用于 Pterodactyl）
  if [[ -n "${SERVER_PORT:-}" ]]; then
    TUIC_PORT="$SERVER_PORT"
    echo "✅ 从环境变量读取 TUIC(QUIC) 端口: $TUIC_PORT"
    return
  fi

  # 3️⃣ 手动输入模式
  local port
  while true; do
    echo "⚙️ 请输入 TUIC(QUIC) 端口 (1024-65535):"
    read -rp
