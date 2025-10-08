#!/bin/bash
# =============================================
# TUIC v5 over QUIC 一键部署脚本（爪云 LXC VPS 适配版）
# 所有文件都放在 /data/tuic
# =============================================

set -e

BASE_DIR="/data/tuic"
MASQ_DOMAIN="www.bing.com"
TUIC_BIN="$BASE_DIR/tuic-server"
SERVER_TOML="$BASE_DIR/server.toml"
CERT_PEM="$BASE_DIR/tuic-cert.pem"
KEY_PEM="$BASE_DIR/tuic-key.pem"
LINK_TXT="$BASE_DIR/tuic_link.txt"

mkdir -p "$BASE_DIR"
cd "$BASE_DIR"

# ===================== 安装依赖 =====================
install_deps() {
  echo "🔍 检查系统依赖..."
  DEPS="curl bash openssl uuidgen file"
  MISSING=""
  for dep in $DEPS; do
    command -v $dep >/dev/null 2>&1 || MISSING="$MISSING $dep"
  done

  if [ -n "$MISSING" ]; then
    echo "📦 安装缺失依赖:$MISSING"
    if [ -f /etc/alpine-release ]; then
      apk add --no-cache $MISSING >/dev/null 2>&1
    elif [ -f /etc/debian_version ]; then
      apt-get update -y >/dev/null 2>&1
      apt-get install -y $MISSING >/dev
