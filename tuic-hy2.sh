#!/bin/bash
# TUIC v5 over QUIC 自动部署脚本（支持 Alpine glibc 自动修复）
set -euo pipefail
IFS=$'\n\t'

MASQ_DOMAIN="www.bing.com"
SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
LINK_TXT="tuic_link.txt"
TUIC_BIN="./tuic-server"

# ===================== 检查并安装依赖 =====================
check_dependencies() {
  echo "🔍 检查必要依赖..."
  local deps=("openssl" "curl")
  local missing_deps=()

  for dep in "${deps[@]}"; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      missing_deps+=("$dep")
    fi
  done

  if [[ ${#missing_deps[@]} -gt 0 ]]; then
    echo "📦 正在安装缺失的依赖: ${missing_deps[*]}..."
    if command -v apk >/dev/null 2>&1; then
      apk add --no-cache "${missing_deps[@]}" >/dev/null 2>&1
    elif command -v apt >/dev/null 2>&1; then
      apt update -y >/dev/null 2>&1 && apt install -y "${missing_deps[@]}" >/dev/null 2>&1
    else
      echo "❌ 无法识别包管理器，请手动安装 ${missing_deps[*]}"
      exit 1
    fi
    echo "✅ 依赖安装完成"
