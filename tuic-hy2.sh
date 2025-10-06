#!/bin/sh
# ============================
# TUIC v5 自动部署脚本（Alpine兼容）
# ============================

set -e

MASQ_DOMAIN="www.bing.com"     # 固定伪装域名
SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
LINK_TXT="tuic_link.txt"
TUIC_BIN="./tuic-server"

# ---------- 读取端口 ----------
read_port() {
  if [ -n "$1" ]; then
    TUIC_PORT="$1"
    echo "✅ 从命令行参数读取端口: $TUIC_PORT"
    return
  fi
  if [ -n "$SERVER_PORT" ]; then
    TUIC_PORT="$SERVER_PORT"
    echo "✅ 从环境变量读取端口: $TUIC_PORT"
    return
  fi
  while :; do
    echo "⚙️ 请输入 TUIC(QUIC) 端口 (1024-65535):"
    read port
    case $port in
      ''|*[!0-9]*|[0-9]|[0-9][0-9]|[0-9][0-9][0-9])
        echo "❌ 无效端口";;
      *)
        if [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; then
          TUIC_PORT="$port"
          break
        fi
        ;;
    esac
  done
}

# ---------- 加载已有配置 ----------
load_config() {
  [ ! -f "$SERVER_TOML" ] && return 1
  TUIC_PORT=$(grep '^server =' "$SERVER_TOML" | sed -E 's/.*:(.*)\"/\1/')
  TUIC_UUID=$(grep '^\[users\]' -A1 "$SERVE_
