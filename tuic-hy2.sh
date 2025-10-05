#!/bin/bash
# TUIC/Hysteria2 统一部署与卸载脚本
# 兼容系统: Alpine, Debian, Ubuntu, CentOS

set -euo pipefail
IFS=$'\n\t'

# ===================== 全局变量与配置 =====================

# --- TUIC 配置 ---
TUIC_MASQ_DOMAIN="www.bing.com"
TUIC_SERVER_TOML="tuic_server.toml"
TUIC_CERT_PEM="tuic_cert.pem"
TUIC_KEY_PEM="tuic_key.pem"
TUIC_LINK_TXT="tuic_link.txt"
TUIC_BIN="./tuic-server"
TUIC_URL="https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-x86_64-linux"

# --- Hysteria2 配置 ---
HY2_MASQ_DOMAIN="www.cloudflare.com"
HY2_CONFIG_YAML="hy2_config.yaml"
HY2_CERT_PEM="hy2_cert.pem"
HY2_KEY_PEM="hy2_key.pem"
HY2_LINK_TXT="hy2_link.txt"
HYSTERIA_VERSION="v2.6.4" # 使用最新版本
HY2_BIN="./hysteria2-server" # 统一的执行文件名
# HY2_URL will be constructed dynamically

# --- 通用变量 ---
SERVICE_NAME="" # 动态设置
SERVICE_DIR="/usr/local/proxy-service"
PROXY_PORT=""
PROXY_UUID=""
PROXY_PASSWORD=""

# ===================== 实用函数 =====================

# 检查权限
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "❌ 请使用 root 用户运行此脚本。"
        exit 1
    fi
}

# 自动检测操作系统并安装依赖
install_dependencies() {
    echo "🔍 正在检测操作系统并安装依赖..."
    local ID
    ID=$(grep -E '^(ID)=' /etc/os-release 2>/dev/null | awk -F= '{print $2}' | sed 's/"//g' || echo "unknown")

    if command -v curl >/dev/null && command -v openssl >/dev/null && command -v uuidgen >/dev/null; then
        echo "✅ 依赖 (curl, openssl, uuidgen) 已安装。"
        return
    fi

    case "$ID" in
        debian|ubuntu)
            apt update -qq >/dev/null
            apt install -y curl openssl uuid-runtime >/dev/null
            ;;
        centos|fedora|rhel)
            yum install -y curl openssl uuidgen >/dev/null
            ;;
        alpine)
            apk update >/dev/null
            apk add curl openssl uuidgen >/dev/null
            ;;
        *)
            echo "❌ 暂不支持的操作系统: $ID"
            echo "请手动安装 curl, openssl, uuidgen。"
            exit 1
            ;;
    esac
    echo "✅ 依赖安装完成。"
}

# 统一的架构检测函数
arch_name() {
    local machine
    machine=$(uname -m | tr '[:upper:]' '[:lower:]')
    if [[ "$machine" == *"arm64"* ]] || [[ "$machine" == *"aarch64"* ]]; then
        echo "arm64"
    elif [[ "$machine" == *"x86_64"* ]] || [[ "$machine" == *"amd64"* ]]; then
        echo "amd64"
    else
        echo ""
    fi
}

# 生成随机端口（用于端口跳跃）
generate_random_port() {
    local min_port="$1"
    local max_port="$2"
    
    # 确保最小值小于或等于最大值
    if [ "$min_port" -gt "$max_port" ]; then
        echo "❌ 端口范围无效 ($min_port > $max_port)。"
        return 1
    fi

    # 计算范围大小
    local range=$((max_port - min_port + 1))
    
    # 生成随机数并调整到范围内
    PROXY_PORT=$(( (RANDOM % range) + min_port ))
    echo "✅ 已生成随机端口: $PROXY_PORT"
    return 0
}

# 读取端口逻辑
read_port() {
    local port_mode
    local min_p max_p
    
    echo "----------------------------------------------------"
    echo "1) 单一端口 (例如: 44333)"
    echo "2) 随机端口跳跃 (例如: 10000-20000 之间随机选一个)"
    read -rp "请选择端口设置模式 (1/2): " port_mode

    if [[ "$port_mode" == "2" ]]; then
        while true; do
            read -rp "请输入端口范围 (MIN-MAX, 例如 10000-20000): " port_range
            if [[ "$port_range" =~ ^[0-9]+-[0-9]+$ ]]; then
                min_p=$(echo "$port_range" | awk -F'-' '{print $1}')
                max_p=$(echo "$port_range" | awk -F'-' '{print $2}')
                
                if [[ "$min_p" -ge 1024 && "$max_p" -le 65535 && "$min_p" -le "$max_p" ]]; then
                    generate_random_port "$min_p" "$max_p"
                    return 0
                fi
            fi
            echo "❌ 无效端口范围，请确保在 1024-65535 之间，且最小值不大于最大值。"
        done
    else # 默认模式 1 或其他无效输入
        # 1. 优先捕获命令行参数 $1
        if [[ $# -ge 1 && -n "${1:-}" ]]; then
            local port_arg="$1"
            if [[ "$port_arg" =~ ^[0-9]+$ && "$port_arg" -ge 1024 && "$port_arg" -le 65535 ]]; then
                PROXY_PORT="$port_arg"
                echo "✅ 从命令行参数读取端口: $PROXY_PORT"
                return 0
            fi
        fi

        # 2. 检查环境变量
        if [[ -n "${SERVER_PORT:-}" ]]; then
            PROXY_PORT="$SERVER_PORT"
            echo "✅ 从环境变量读取端口: $PROXY_PORT"
            return 0
        fi

        # 3. 手动输入
        while true; do
            echo "⚙️ 请输入代理端口 (1024-65535):"
            read -rp "> " port
            if [[ ! "$port" =~ ^[0-9]+$ || "$port" -lt 1024 || "$port" -gt 65535 ]]; then
                echo "❌ 无效端口: $port"
                continue
            fi
            PROXY_PORT="$port"
            break
        done
    fi
}

# 生成自签证书
generate_cert() {
    local CERT_FILE="$1"
    local KEY_FILE="$2"
    local DOMAIN="$3"
    
    if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        echo "🔐 检测到已有证书，跳过生成"
        return
    fi
    echo "🔐 生成自签 ECDSA-P256 证书..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${DOMAIN}" -days 365 -nodes >/dev/null 2>&1
    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"
    echo "✅ 自签证书生成完成"
}

# 获取公网 IP
get_server_ip() {
    ip=$(curl -s --connect-timeout 3 https://api.ipify.org || true)
    echo "${ip:-YOUR_SERVER_IP}"
}

# ===================== TUIC 部署逻辑 =====================

deploy_tuic() {
    SERVICE_NAME="tuic"
    
    # 1. 加载或读取配置
    # 注意: TUIC 使用 server.toml 作为配置检测文件
    if [[ -f "$SERVICE_DIR/$TUIC_SERVER_TOML" ]]; then
        echo "⚠️ 检测到TUIC配置，跳过参数读取和新生成UUID/密码。"
    elif ! load_existing_config; then
        echo "⚙️ 第一次运行，开始初始化..."
        read_port "$@"
        PROXY_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null)"
        PROXY_PASSWORD="$(openssl rand -hex 16)"
        echo "🔑 UUID: $PROXY_UUID"
        echo "🔑 密码: $PROXY_PASSWORD"
    fi
    
    echo "🎯 SNI: ${TUIC_MASQ_DOMAIN}"

    # 2. 证书和二进制文件
    generate_cert "$TUIC_CERT_PEM" "$TUIC_KEY_PEM" "$TUIC_MASQ_DOMAIN"
    
    if [[ ! -x "$TUIC_BIN" ]]; then
        echo "📥 未找到 tuic-server，正在下载..."
        local ARCH
        ARCH=$(uname -m)
        if [[ "$ARCH" != "x86_64" ]]; then
            echo "❌ 暂不支持架构: $ARCH"
            exit 1
        fi
        if curl -L -f -o "$TUIC_BIN" "$TUIC_URL"; then
            chmod +x "$TUIC_BIN"
            echo "✅ tuic-server 下载完成"
        else
            echo "❌ 下载失败，请手动下载 $TUIC_URL"
            exit 1
        fi
    fi

    # 3. 生成 TUIC 配置文件 (server.toml)
cat > "$TUIC_SERVER_TOML" <<EOF
log_level = "off"
server = "0.0.0.0:${PROXY_PORT}"

udp_relay_ipv6 = false
zero_rtt_handshake = true
dual_stack = false
auth_timeout = "10s"
task_negotiation_timeout = "5s"
gc_interval = "10s"
gc_lifetime = "10s"
max_external_packet_size = 8192

[users]
${PROXY_UUID} = "${PROXY_PASSWORD}"

[tls]
self_sign = false
certificate = "$TUIC_CERT_PEM"
private_key = "$TUIC_KEY_PEM"
alpn = ["h3"]

[restful]
addr = "127.0.0.1:${PROXY_PORT}"
secret = "$(openssl rand -hex 16)"
maximum_clients_per_user = 999999999

[quic]
initial_mtu = 1500
min_mtu = 1200
gso = true
pmtu = true
send_window = 33554432
receive_window = 16777216
max_idle_time = "20s"

[quic.congestion_control]
controller = "bbr"
initial_window = 4194304
EOF

    # 4. 生成链接并运行
    local ip
    ip="$(get_server_ip)"
    generate_tuic_link "$ip"
    run_background_loop "$TUIC_BIN" "$TUIC_SERVER_TOML"
}

generate_tuic_link() {
    local ip="$1"
    cat > "$TUIC_LINK_TXT" <<EOF
tuic://${PROXY_UUID}:${PROXY_PASSWORD}@${ip}:${PROXY_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${TUIC_MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${ip}
EOF
    echo ""
    echo "📱 TUIC 链接已生成并保存到 $TUIC_LINK_TXT"
    echo "🔗 链接内容："
    cat "$TUIC_LINK_TXT"
    echo ""
}

# ===================== Hysteria2 部署逻辑 =====================

deploy_hysteria2() {
    SERVICE_NAME="hysteria2"
    
    # 1. 加载或读取配置
    # Hysteria2 不使用 UUID，但使用相同的 PROXY_PASSWORD/PROXY_UUID 变量来存储密码
    # 注意: Hysteria2 使用 hy2_config.yaml 作为配置检测文件
    if [[ -f "$SERVICE_DIR/$HY2_CONFIG_YAML" ]]; then
        echo "⚠️ 检测到Hysteria2配置，跳过参数读取和新生成密码。"
    elif ! load_existing_config; then
        echo "⚙️ 第一次运行，开始初始化..."
        read_port "$@"
        # 使用随机密码，而不是固定的 "ieshare2025"
        PROXY_PASSWORD="$(openssl rand -hex 16)"
        echo "🔑 密码: $PROXY_PASSWORD"
    fi
    
    echo "🎯 SNI: ${HY2_MASQ_DOMAIN}"

    # 2. 证书和二进制文件
    generate_cert "$HY2_CERT_PEM" "$HY2_KEY_PEM" "$HY2_MASQ_DOMAIN"
    
    local ARCH_CODE
    ARCH_CODE=$(arch_name)
    if [ -z "$ARCH_CODE" ]; then
        echo "❌ 无法识别 CPU 架构: $(uname -m)。"
        exit 1
    fi
    
    local HY2_BIN_DOWNLOAD="hysteria-linux-${ARCH_CODE}"
    local HY2_URL_FULL="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${HY2_BIN_DOWNLOAD}"

    if [[ ! -x "$HY2_BIN" ]]; then
        echo "📥 未找到 hysteria2-server，正在下载 ${HYSTERIA_VERSION} for ${ARCH_CODE}..."
        
        if curl -L -f -o "$HY2_BIN_DOWNLOAD" "$HY2_URL_FULL"; then
            chmod +x "$HY2_BIN_DOWNLOAD"
            mv "$HY2_BIN_DOWNLOAD" "$HY2_BIN" # 下载后重命名为统一的执行文件
            echo "✅ Hysteria2 Server 下载并重命名完成: $HY2_BIN"
        else
            echo "❌ 下载失败，请手动下载 $HY2_URL_FULL"
            exit 1
        fi
    fi

    # 3. 生成 Hysteria2 配置文件 (config.yaml)
cat > "$HY2_CONFIG_YAML" <<EOF
listen: :${PROXY_PORT}
auth:
  type: password
  password: ${PROXY_PASSWORD}
tls:
  cert: ${HY2_CERT_PEM}
  key: ${HY2_KEY_PEM}
  insecure: true
  sni: ${HY2_MASQ_DOMAIN}
  alpn:
    - h3
obfs:
  type: none
EOF

    # 4. 生成链接并运行
    local ip
    ip="$(get_server_ip)"
    generate_hy2_link "$ip"
    # 注意：Hysteria2 执行命令是 ./hysteria2-server -c config.yaml
    run_background_loop "$HY2_BIN" "-c" "$HY2_CONFIG_YAML"
}

generate_hy2_link() {
    local ip="$1"
    cat > "$HY2_LINK_TXT" <<EOF
hy2://${PROXY_PASSWORD}@${ip}:${PROXY_PORT}?insecure=1&sni=${HY2_MASQ_DOMAIN}&obfs=none#HY2-${ip}
EOF
    echo ""
    echo "📱 Hysteria2 链接已生成并保存到 $HY2_LINK_TXT"
    echo "🔗 链接内容："
    cat "$HY2_LINK_TXT"
    echo ""
}


# ===================== 服务运行与卸载 =====================

# 检查/加载现有配置（此函数主要用于初次安装时跳过输入）
load_existing_config() {
  if [[ -f "$TUIC_SERVER_TOML" ]]; then
    # 从 TUIC 配置加载
    PROXY_PORT=$(grep '^server =' "$TUIC_SERVER_TOML" | sed -E 's/.*:(.*)\"/\1/' || echo "")
    PROXY_UUID=$(grep '^\[users\]' -A1 "$TUIC_SERVER_TOML" | tail -n1 | awk '{print $1}' || echo "")
    PROXY_PASSWORD=$(grep '^\[users\]' -A1 "$TUIC_SERVER_TOML" | tail -n1 | awk -F'"' '{print $2}' || echo "")
    echo "📂 检测到已有 TUIC 配置，加载中..."
    return 0
  elif [[ -f "$HY2_CONFIG_YAML" ]]; then
    # 从 Hysteria2 配置加载
    PROXY_PORT=$(grep '^listen: ' "$HY2_CONFIG_YAML" | sed -E 's/.*:([0-9]+)/\1/' || echo "")
    PROXY_PASSWORD=$(grep '^  password: ' "$HY2_CONFIG_YAML" | awk '{print $2}' || echo "")
    echo "📂 检测到已有 Hysteria2 配置，加载中..."
    return 0
  fi
  return 1
}


# 后台循环守护 (保持与原 TUIC 脚本的运行风格一致)
run_background_loop() {
    local BINARY="$1"
    local CONFIG_CMD_ARG="${2:-}"
    local CONFIG_FILE="${3:-}"
    
    echo "----------------------------------------------------"
    echo "✅ 服务已启动，进程正在后台运行..."
    echo "❗ 注意：当前脚本采用前台循环守护方式，若需长期稳定运行，请配置 systemd。"
    echo "----------------------------------------------------"

    while true; do
        if [[ -z "$CONFIG_FILE" ]]; then
            # TUIC: ./tuic-server -c tuic_server.toml
            "$BINARY" -c "$CONFIG_CMD_ARG"
        else
            # Hysteria2: ./hysteria2-server -c hy2_config.yaml
            "$BINARY" "$CONFIG_CMD_ARG" "$CONFIG_FILE"
        fi
        
        echo "⚠️ ${SERVICE_NAME} 服务已退出，5秒后重启..."
        sleep 5
    done
}

# 卸载服务
uninstall_service() {
    echo "🛑 正在停止所有代理服务相关进程..."
    pkill -f "tuic-server" || true
    pkill -f "hysteria2-server" || true
    
    echo "🗑️ 正在删除文件和配置..."
    if [ -d "$SERVICE_DIR" ]; then
        rm -rf "$SERVICE_DIR"
        echo "✅ $SERVICE_DIR 目录已删除。"
    fi
    
    echo "🎉 所有代理服务已卸载完成！"
    exit 0
}

# ===================== 主菜单 =====================

main_menu() {
    local CHOICE
    local PROTOCOL
    
    echo "===================================================="
    echo "⭐ TUIC / Hysteria2 统一部署脚本 ⭐"
    echo "===================================================="
    echo "请选择操作："
    echo "1) 安装 / 更新代理服务"
    echo "2) 卸载所有服务"
    echo "3) 退出"
    echo "----------------------------------------------------"

    read -rp "输入选项 (1/2/3): " CHOICE

    case "$CHOICE" in
        1)
            echo "----------------------------------------------------"
            echo "请选择要部署的协议："
            echo "1) TUIC v5 (基于 QUIC，高速)"
            echo "2) Hysteria2 (基于 QUIC/UDP，抗审查)"
            read -rp "输入选项 (1/2): " PROTOCOL
            
            if [[ "$PROTOCOL" == "1" ]]; then
                PROTOCOL="tuic"
            elif [[ "$PROTOCOL" == "2" ]]; then
                PROTOCOL="hysteria2"
            else
                echo "❌ 无效的选择，退出。"
                exit 1
            fi
            
            # 创建工作目录并进入
            mkdir -p "$SERVICE_DIR"
            cd "$SERVICE_DIR"
            
            install_dependencies
            
            if [[ "$PROTOCOL" == "tuic" ]]; then
                deploy_tuic "$@"
            elif [[ "$PROTOCOL" == "hysteria2" ]]; then
                deploy_hysteria2 "$@"
            fi
            ;;
        2)
            uninstall_service
            ;;
        3)
            echo "👋 脚本已退出。"
            exit 0
            ;;
        *)
            echo "❌ 无效的选项。"
            main_menu
            ;;
    esac
}

# ===================== 脚本入口 =====================

main() {
    check_root
    # 传递所有命令行参数给主菜单，以便在安装流程中被 read_port 使用
    main_menu "$@"
}

main "$@"
