#!/bin/bash
# =============================================
# TUIC v5 over QUIC 一键部署脚本（支持 Alpine / Debian）
# 自动检测 Alpine 并安装 glibc 兼容层
# 更新版：增加二进制验证，防止无限重启
# =============================================

set -euo pipefail
IFS=$'\n\t'

MASQ_DOMAIN="www.bing.com"  # 伪装域名
SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
LINK_TXT="tuic_link.txt"
TUIC_BIN="./tuic-server"

# ===================== 检查并安装依赖 =====================
check_dependencies() {
  echo "🔍 检查系统环境与依赖..."
  local deps=("openssl" "curl" "grep" "sed" "coreutils")
  local missing=()

  for dep in "${deps[@]}"; do
    command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
  done

  # 检测系统类型
  if grep -qi 'alpine' /etc/os-release 2>/dev/null; then
    OS_TYPE="alpine"
  elif grep -qi 'debian' /etc/os-release 2>/dev/null || grep -qi 'ubuntu' /etc/os-release 2>/dev/null; then
    OS_TYPE="debian"
  elif grep -qi 'centos' /etc/os-release 2>/dev/null || grep -qi 'rocky' /etc/os-release 2>/dev/null; then
    OS_TYPE="centos"
  else
    OS_TYPE="unknown"
  fi

  echo "🧠 检测到系统类型: $OS_TYPE"

  # 安装缺失依赖
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "📦 正在安装依赖: ${missing[*]}"
    case "$OS_TYPE" in
      alpine)
        apk add --no-cache "${missing[@]}" >/dev/null 2>&1 || true
        ;;
      debian)
        apt-get update -y >/dev/null 2>&1
        apt-get install -y "${missing[@]}" >/dev/null 2>&1 || true
        ;;
      centos)
        yum install -y "${missing[@]}" >/dev/null 2>&1 || true
        ;;
      *)
        echo "⚠️ 无法识别的系统，请手动安装依赖: ${missing[*]}"
        ;;
    esac
  fi

  # 安装 uuidgen
  if ! command -v uuidgen >/dev/null 2>&1; then
    echo "📦 安装 util-linux..."
    case "$OS_TYPE" in
      alpine) apk add --no-cache util-linux >/dev/null 2>&1 ;;
      debian) apt-get install -y util-linux >/dev/null 2>&1 ;;
      centos) yum install -y util-linux >/dev/null 2>&1 ;;
    esac
  fi

  # 如果是 Alpine，安装 glibc 兼容层
  if [[ "$OS_TYPE" == "alpine" ]]; then
    echo "🔧 检查 glibc 兼容层..."
    if ! ls /lib/libc.musl* >/dev/null 2>&1; then
      echo "⚠️ 未检测到 musl glibc 文件，可能是非标准 Alpine 环境。"
    fi
    if ! ls /usr/glibc-compat/lib/libc.so.6 >/dev/nul
