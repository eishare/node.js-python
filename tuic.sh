#!/usr/bin/env bash
# tuic-nonroot.sh — TUIC v5 部署（非 root 友好版）
set -euo pipefail
IFS=$'\n\t'

# ---------- 可调整项 ----------
MASQ_DOMAIN="${MASQ_DOMAIN:-www.bing.com}"
BIN_DIR="${HOME}/.local/bin"
CONF_DIR="${HOME}/.tuic"
LOG_FILE="${CONF_DIR}/tuic.log"
PID_FILE="${CONF_DIR}/tuic.pid"
TUIC_BIN="${BIN_DIR}/tuic-server"
TUIC_JSON="${CONF_DIR}/tuic.json"
# --------------------------------

# 简单输出函数
info(){ printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err(){ printf "\033[1;31m[ERROR]\033[0m %s\n" "$*"; }

# 参数：可传端口
if [[ $# -ge 1 && -n "${1:-}" ]]; then
  TUIC_PORT="$1"
else
  TUIC_PORT=$((RANDOM % 40000 + 10000))
fi

# 依赖检查（不自动安装，只提示）
check_deps() {
  local miss=()
  for cmd in curl wget openssl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      miss+=("$cmd")
    fi
  done
  if ((${#miss[@]})); then
    warn "缺少依赖：${miss[*]}"
    warn "若可用 root，请安装这些依赖（例如 Debian/Ubuntu: sudo apt update && sudo apt install -y ${miss[*]})"
    warn "脚本仍可继续，但部分操作（如下载或证书生成）可能失败。"
  fi
}

# 下载 tuic-server（尝试多种方式）
download_tuic() {
  mkdir -p "$BIN_DIR"
  if [[ -x "$TUIC_BIN" ]]; then
    info "检测到已存在 tuic-server：$TUIC_BIN"
    return 0
  fi

  info "尝试下载 tuic-server 到 $TUIC_BIN ..."
  # 优先用 GitHub Releases API 去找 x86_64 二进制（若失败回退到固定 URL）
  if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    api="https://api.github.com/repos/EAimTY/tuic/releases/latest"
    url=$(curl -s "$api" | jq -r '.assets[]?.browser_download_url | select(test("x86_64|linux"))' | head -n1 || true)
    if [[ -n "$url" ]]; then
      curl -fsSL "$url" -o "$TUIC_BIN" || true
    fi
  fi

  # 回退下载（历史兼容链接）
  if [[ ! -s "$TUIC_BIN" ]]; then
    # 这是一个常见的 tuic-server 名称 URL（如果你有更可靠的 URL 可替换）
    fallback="https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-x86_64-linux"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$fallback" -o "$TUIC_BIN" || true
    elif command -v wget >/dev/null 2>&1; then
      wget -qO "$TUIC_BIN" "$fallback" || true
    fi
  fi

  if [[ -s "$TUIC_BIN" ]]; then
    chmod +x "$TUIC_BIN" || true
    info "下载成功：$TUIC_BIN"
    return 0
  fi

  err "无法自动下载 tuic-server。请手动将 tuic-server 放到 $TUIC_BIN 并赋予可执行权限。"
  return 1
}

# 生成自签证书（放用户目录下）
generate_cert() {
  mkdir -p "$CONF_DIR"
  CERT_PEM="${CONF_DIR}/tuic-cert.pem"
  KEY_PEM="${CONF_DIR}/tuic-key.pem"
  if [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]]; then
    info "检测到已有证书，跳过生成"
    return 0
  fi
  if ! command -v openssl >/dev/null 2>&1; then
    warn "缺少 openssl，无法生成证书。请在有权环境安装 openssl 或手动准备证书。"
    return 1
  fi
  info "生成自签 ECDSA-P256 证书（有效期 365 天）..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
  chmod 600 "$KEY_PEM" || true
  chmod 644 "$CERT_PEM" || true
  info "证书生成完成：$CERT_PEM"
}

# 生成配置（JSON 格式，tuic-server 支持 toml/json 视版本而定）
generate_config() {
  mkdir -p "$CONF_DIR"
  UUID="${UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "user-$(date +%s)")}"
  PASSWORD="${PASSWORD:-$(openssl rand -hex 12 2>/dev/null || head -c12 /dev/urandom | base64)}"
  CERT_PEM="${CERT_PEM:-${CONF_DIR}/tuic-cert.pem}"
  KEY_PEM="${KEY_PEM:-${CONF_DIR}/tuic-key.pem}"

  info "生成配置文件：$TUIC_JSON"
  cat > "$TUIC_JSON" <<EOF
{
  "server": "0.0.0.0:${TUIC_PORT}",
  "users": {
    "${UUID}": "${PASSWORD}"
  },
  "certificate": "${CERT_PEM}",
  "private_key": "${KEY_PEM}",
  "alpn": ["h3"],
  "congestion_control": "bbr",
  "zero_rtt_handshake": true,
  "heartbeat_interval": "15s",
  "max_idle_time": "600s",
  "disable_sni": false,
  "server_name": "${MASQ_DOMAIN}",
  "log_level": "warn",
  "log_file": "${LOG_FILE}"
}
EOF
  info "配置生成完成"
}

# 启动 tuic-server（非 root 版）
start_tuic_nonroot() {
  mkdir -p "$CONF_DIR"
  if [[ ! -x "$TUIC_BIN" ]]; then
    err "缺少可执行 tuic-server：$TUIC_BIN"
    return 1
  fi

  # 若已有 pid 且进程存在，提示
  if [[ -f "$PID_FILE" ]]; then
    oldpid=$(cat "$PID_FILE" 2>/dev/null || echo)
    if [[ -n "$oldpid" && -d /proc/"$oldpid" ]]; then
      warn "检测到 tuic 进程正在运行 (PID $oldpid)，如需重启请手动杀掉该进程。"
      return 0
    fi
  fi

  info "使用 nohup 后台启动 tuic-server，日志写入：$LOG_FILE"
  nohup "$TUIC_BIN" -c "$TUIC_JSON" >> "$LOG_FILE" 2>&1 &
  pid=$!
  echo "$pid" > "$PID_FILE"
  info "tuic-server 已启动（PID $pid）"
}

# 生成客户端链接文本
generate_link() {
  ip="$(curl -s ifconfig.me || curl -s https://api.ipify.org || echo 'YOUR_SERVER_IP')"
  LINK_FILE="${CONF_DIR}/tuic_link.txt"
  cat > "$LINK_FILE" <<EOF
tuic://${UUID}:${PASSWORD}@${ip}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${ip}
EOF
  info "TUIC 链接已保存：$LINK_FILE"
  printf "\n链接（示例）：\n"; sed -n '1p' "$LINK_FILE"; printf "\n"
}

# 主流程
main() {
  info "启动 tuic 非 root 部署流程"
  check_deps || true
  download_tuic || true
  generate_cert || true
  generate_config
  # BBR 仅在 root 时尝试启用（非 root 跳过）
  if [[ $(id -u) -eq 0 ]]; then
    # 尝试启用 bbr
    if modprobe tcp_bbr 2>/dev/null; then
      sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
      sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
      info "BBR 尝试启用（root）。"
    else
      warn "系统不支持或无法加载 tcp_bbr。"
    fi
  else
    warn "非 root，跳过启用 BBR（若需要，请以 root 运行脚本或手动启用）"
  fi

  start_tuic_nonroot
  generate_link

  info "完成：配置文件 $TUIC_JSON，二进制 $TUIC_BIN，日志 $LOG_FILE，PID $PID_FILE"
  info "如需停止： kill \$(cat $PID_FILE) && rm -f $PID_FILE"
}

main "$@"
