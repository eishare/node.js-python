#!/usr/bin/env bash
# TUIC v5 over QUIC 极简一键部署（Alpine/Debian/Ubuntu/CentOS）
# 支持端口参数传入、随机端口跳跃、自恢复、卸载
set -euo pipefail
IFS=$'\n\t'

# ------------------ 配置 ------------------
PORT="${1:-0}"          # 可通过命令行传入端口
PORT_RANGE=1000          # 随机端口跳跃范围
TUIC_BIN="/usr/local/bin/tuic-server"
TUIC_SERVICE="tuic-server"
SERVER_TOML="/etc/tuic-server.toml"
CERT_FILE="/etc/tuic-cert.pem"
KEY_FILE="/etc/tuic-key.pem"
LINK_TXT="/etc/tuic_link.txt"
DOMAIN="www.bing.com"
# ----------------------------------------

# ------------------ 端口处理 ------------------
if [[ "$PORT" -eq 0 ]]; then
    BASE_PORT=40000
    PORT=$((BASE_PORT + RANDOM % PORT_RANGE))
fi
echo "🎯 TUIC 将使用端口: $PORT"

# ------------------ 安装依赖 ------------------
if command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl openssl bash
elif command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y curl openssl bash
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl openssl bash
fi

# ------------------ 下载 TUIC ------------------
download_tuic() {
    if [[ -x "$TUIC_BIN" ]]; then
        echo "✅ TUIC 已安装: $TUIC_BIN"
        return
    fi
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) TUIC_URL="https://github.com/EAimTY/tuic/releases/download/v1.0.0/tuic-server-x86_64-linux" ;;
        aarch64|arm64) TUIC_URL="https://github.com/EAimTY/tuic/releases/download/v1.0.0/tuic-server-aarch64-linux" ;;
        *) echo "❌ 暂不支持架构: $ARCH"; exit 1 ;;
    esac
    echo "⏳ 下载 TUIC: $TUIC_URL"
    curl -L -o "$TUIC_BIN" "$TUIC_URL"
    chmod +x "$TUIC_BIN"
    echo "✅ TUIC 安装完成"
}

# ------------------ 生成证书 ------------------
generate_cert() {
    if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        echo
