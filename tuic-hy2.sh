#!/bin/bash
# TUIC/Hysteria2 统一部署与卸载脚本
# 兼容系统: Alpine, Debian, Ubuntu, CentOS
#
# 一键执行格式:
# 1. 安装指定协议和端口: sudo ./unified_proxy_installer.sh <tuic|hysteria2> <端口号>
# 2. 安装指定协议和端口跳跃: sudo ./unified_proxy_installer.sh <tuic|hysteria2> <MIN-MAX>
# 3. 卸载: sudo ./unified_proxy_installer.sh uninstall

# 仅保留 -e (遇到错误退出) 和 -u (使用未定义变量报错)
set -eu

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
HYSTERIA_VERSION="v2.6.4" 
HY2_BIN="./hysteria2-server"

# --- 通用变量 ---
SERVICE_NAME="" 
SERVICE_DIR="/usr/local/proxy-service"
PROXY_PORT=""
PROXY_UUID=""
PROXY_PASSWORD=""

# ===================== 实用函数 =====================

# 检查权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "❌ 请使用 root 用户运行此脚本。"
        exit 1
    fi
}

# 自动检测操作系统并安装依赖
install_dependencies() {
    echo "🔍 正在检测操作系统并安装依赖..."
    local ID
    ID=$(grep -E '^(ID)=' /etc/os-release 2>/dev/null | awk -F= '{print $2}' | sed 's/"//g' || echo "unknown")

    # 仅检查 curl 和 openssl
    if command -v curl >/dev/null && command -v openssl >/dev/null; then
        echo "✅ 依赖 (curl, openssl) 已安装。"
        return
    fi

    case "$ID" in
        debian|ubuntu)
            apt update -qq >/dev/null
            apt install -y curl openssl >/dev/null
            ;;
        centos|fedora|rhel)
            yum install -y curl openssl >/dev/null
            ;;
        alpine)
            apk update >/dev/null
            apk add curl openssl >/dev/null
            ;;
        *)
            echo "❌ 暂不支持的操作系统: $ID"
            echo "请手动安装 curl, openssl。"
            exit 1
            ;;
    esac
    echo "✅ 依赖安装完成。"
}

# 统一的架构检测函数
arch_name() {
    local machine
    # 使用 tr 确保兼容性
    machine=$(uname -m | tr '[:upper:]' '[:lower:]')
    case "$machine" in
        *arm64*|*aarch64*)
            echo "arm64"
            ;;
        *x86_64*|*amd64*)
            echo "amd64"
            ;;
        *)
            echo ""
            ;;
    esac
}

# 生成随机端口（用于端口跳跃）
generate_random_port() {
    local min_port="$1"
    local max_port="$2"
    
    if [ "$min_port" -gt "$max_port" ]; then
        echo "❌ 端口范围无效 ($min_port > $max_port)。"
        return 1
    fi
    local range
    range=$((max_port - min_port + 1))
    PROXY_PORT=$(( (RANDOM % range) + min_port ))
    echo "✅ 已生成随机端口: $PROXY_PORT"
    return 0
}

# 生成安全的 UUID (兼容 Alpine/极简环境)
generate_safe_uuid() {
    local uuid
    # 使用兼容 POSIX 的 /dev/urandom 方式
    uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || \
        head -c 16 /dev/urandom | od -An -t x1 | tr -d ' \n' | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')
    echo "$uuid"
}

# 生成安全的 32 字符十六进制密码/密钥 (兼容 Alpine/极简环境)
generate_safe_password() {
    head -c 16 /dev/urandom | od -An -t x1 | tr -d ' \n'
}

# 读取端口逻辑 (仅在交互模式下调用)
read_port() {
    local port_mode
    local min_p max_p
    
    echo "----------------------------------------------------"
    echo "1) 单一端口 (例如: 44333)"
    echo "2) 随机端口跳跃 (例如: 10000-20000 之间随机选一个)"
    read -rp "请选择端口设置模式 (1/2): " port_mode

    if [ "$port_mode" = "2" ]; then
        while true; do
            read -rp "请输入端口范围 (MIN-MAX, 例如 10000-20000): " port_range
            # 使用更兼容 sh 的 case/grep 验证
            if echo "$port_range" | grep -q '^[0-9]\+-[0-9]\+$'; then
                min_p=$(echo "$port_range" | awk -F'-' '{print $1}')
                max_p=$(echo "$port_range" | awk -F'-' '{print $2}')
                
                # 使用 [ ] 进行算术比较
                if [ "$min_p" -ge 1024 ] && [ "$max_p" -le 65535 ] && [ "$min_p" -le "$max_p" ]; then
                    generate_random_port "$min_p" "$max_p"
                    return 0
                fi
            fi
            echo "❌ 无效端口范围，请确保在 1024-65535 之间，且最小值不大于最大值。"
        done
    else
        # 3. 手动输入
        while true; do
            echo "⚙️ 请输入代理端口 (1024-65535):"
            read -rp "> " port
            if [ -z "$port" ] || ! echo "$port" | grep -q '^[0-9]\+$'; then
                 echo "❌ 无效端口: $port"
                 continue
            fi
            # 使用 [ ] 进行算术比较
            if [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; then
                PROXY_PORT="$port"
                break
            fi
            echo "❌ 端口不在范围内"
        done
    fi
}

# 检查/加载现有配置
load_existing_config() {
  # 使用 [ -f ... ] 代替 [[ -f ... ]] 增加 sh 兼容性
  if [ -f "$SERVICE_DIR/$TUIC_SERVER_TOML" ]; then
    # 从 TUIC 配置加载
    PROXY_PORT=$(grep '^server =' "$SERVICE_DIR/$TUIC_SERVER_TOML" | sed -E 's/.*:([0-9]+)\"/\1/' || echo "")
    PROXY_UUID=$(grep '^\[users\]' -A1 "$SERVICE_DIR/$TUIC_SERVER_TOML" | tail -n1 | awk '{print $1}' || echo "")
    PROXY_PASSWORD=$(grep '^\[users\]' -A1 "$SERVICE_DIR/$TUIC_SERVER_TOML" | tail -n1 | awk -F'"' '{print $2}' || echo "")
    echo "📂 检测到已有 TUIC 配置，加载中..."
    return 0
  elif [ -f "$SERVICE_DIR/$HY2_CONFIG_YAML" ]; then
    # 从 Hysteria2 配置加载
    PROXY_PORT=$(grep '^listen: ' "$SERVICE_DIR/$HY2_CONFIG_YAML" | sed -E 's/.*:([0-9]+)/\1/' || echo "")
    PROXY_PASSWORD=$(grep '^  password: ' "$SERVICE_DIR/$HY2_CONFIG_YAML" | awk '{print $2}' || echo "")
    echo "📂 检测到已有 Hysteria2 配置，加载中..."
    return 0
  fi
  return 1
}

# 生成自签证书
generate_cert() {
    local CERT_FILE="$1"
    local KEY_FILE="$2"
    local DOMAIN="$3"
    
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        echo "🔐 检测到已有证书，跳过生成"
        return
    fi
    echo "🔐 生成自签 ECDSA-P256 证书..."
    
    if ! command -v openssl >/dev/null; then
        echo "❌ openssl 未安装，无法生成证书。请手动安装后再试。"
        exit 1
    fi
    # 使用 openssl 创建证书
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

# 部署 TUIC (此函数假设 PROXY_PORT/UUID/PASSWORD 已经设置好)
deploy_tuic() {
    SERVICE_NAME="tuic"
    
    # 1. 初始化或加载凭证
    if [ -z "$PROXY_UUID" ]; then
        PROXY_UUID=$(generate_safe_uuid)
        PROXY_PASSWORD=$(generate_safe_password)
        echo "🔑 UUID: $PROXY_UUID"
        echo "🔑 密码: $PROXY_PASSWORD"
    fi
    
    echo "🎯 SNI: ${TUIC_MASQ_DOMAIN}"

    # 2. 证书和二进制文件
    generate_cert "$TUIC_CERT_PEM" "$TUIC_KEY_PEM" "$TUIC_MASQ_DOMAIN"
    
    # 使用 [ ] 替代 [[ ]]
    if [ ! -x "$TUIC_BIN" ]; then
        echo "📥 未找到 tuic-server，正在下载..."
        local ARCH
        ARCH=$(uname -m)
        if [ "$ARCH" != "x86_64" ]; then
            echo "❌ 暂不支持架构: $ARCH"
            exit 1
        fi
        
        # 核心兼容性修复: 使用 command || { ... } 结构替代 if ! command; then ... fi
        curl -L -f -o "$TUIC_BIN" "$TUIC_URL" || {
            echo "❌ TUIC Server 下载失败 (Curl Exit Code: $?)。请检查网络和 $SERVICE_DIR 目录权限。"
            exit 1
        }
        
        chmod +x "$TUIC_BIN"
        echo "✅ tuic-server 下载完成"
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
secret = "$(generate_safe_password)"
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

# 部署 Hysteria2 (此函数假设 PROXY_PORT/PASSWORD 已经设置好)
deploy_hysteria2() {
    SERVICE_NAME="hysteria2"
    
    # 1. 初始化或加载凭证
    if [ -z "$PROXY_PASSWORD" ]; then
        PROXY_PASSWORD=$(generate_safe_password)
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

    if [ ! -x "$HY2_BIN" ]; then
        echo "📥 未找到 hysteria2-server，正在下载 ${HYSTERIA_VERSION} for ${ARCH_CODE}..."
        
        # 核心兼容性修复: 使用 command || { ... } 结构替代 if ! command; then ... fi
        curl -L -f -o "$HY2_BIN_DOWNLOAD" "$HY2_URL_FULL" || {
            echo "❌ Hysteria2 Server 下载失败 (Curl Exit Code: $?)。请检查网络和 $SERVICE_DIR 目录权限。"
            exit 1
        }
        
        # 如果下载成功，继续执行
        chmod +x "$HY2_BIN_DOWNLOAD"
        mv "$HY2_BIN_DOWNLOAD" "$HY2_BIN"
        echo "✅ Hysteria2 Server 下载并重命名完成: $HY2_BIN"
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
bandwidth:
  up: "200mbps"
  down: "200mbps"
quic:
  max_idle_timeout: "10s"
  max_concurrent_streams: 4
  initial_stream_receive_window: 65536
  max_stream_receive_window: 131072
  initial_conn_receive_window: 131072
  max_conn_receive_window: 262144
EOF

    # 4. 生成链接并运行
    local ip
    ip="$(get_server_ip)"
    generate_hy2_link "$ip"
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


# ===================== 核心运行与卸载 =====================

# 后台循环守护
run_background_loop() {
    local BINARY="$1"
    local CONFIG_CMD_ARG="${2:-}"
    local CONFIG_FILE="${3:-}"
    
    echo "----------------------------------------------------"
    echo "✅ 服务已启动，进程正在后台运行..."
    echo "----------------------------------------------------"

    while true; do
        # 根据参数决定如何执行，以兼容 tuic 和 hysteria2
        if [ -z "$CONFIG_FILE" ]; then
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


# ===================== 部署入口（一键模式） =====================

install_and_run_non_interactive() {
    local PROTOCOL="$1"
    local PORT_SETTING="$2"

    echo "===================================================="
    echo "⚙️ 自动部署模式激活: $PROTOCOL - 端口设置 $PORT_SETTING"
    echo "===================================================="
    
    # 1. 检查和设置端口
    # 使用 grep/awk 替代 [[ =~ ]] 确保兼容性
    if echo "$PORT_SETTING" | grep -q '^[0-9]\+-[0-9]\+$'; then
        local min_p max_p
        min_p=$(echo "$PORT_SETTING" | awk -F'-' '{print $1}')
        max_p=$(echo "$PORT_SETTING" | awk -F'-' '{print $2}')
        if ! generate_random_port "$min_p" "$max_p"; then
            exit 1
        fi
    elif echo "$PORT_SETTING" | grep -q '^[0-9]\+$'; then
        if [ "$PORT_SETTING" -ge 1024 ] && [ "$PORT_SETTING" -le 65535 ]; then
            PROXY_PORT="$PORT_SETTING"
            echo "✅ 使用指定端口: $PROXY_PORT"
        else
            echo "❌ 端口参数无效。请使用单个端口 (1024-65535) 或范围 (MIN-MAX)。"
            exit 1
        fi
    else
        echo "❌ 端口参数无效。请使用单个端口 (1024-65535) 或范围 (MIN-MAX)。"
        exit 1
    fi
    
    # 2. 检查现有配置
    if load_existing_config; then
        echo "⚠️ 发现已有配置，将尝试使用现有凭证和新端口 $PROXY_PORT 进行更新。"
    fi

    # 3. 开始部署
    mkdir -p "$SERVICE_DIR"
    # 增加健壮性检查，确保能进入目录
    if ! cd "$SERVICE_DIR"; then
        echo "❌ 无法进入服务目录: $SERVICE_DIR"
        exit 1
    fi
    
    install_dependencies
    
    if [ "$PROTOCOL" = "tuic" ]; then
        deploy_tuic
    elif [ "$PROTOCOL" = "hysteria2" ]; then
        deploy_hysteria2
    fi
}


# ===================== 交互式入口 =====================

main_menu() {
    local CHOICE
    local PROTOCOL
    
    echo "===================================================="
    echo "⭐ TUIC / Hysteria2 统一部署脚本 ⭐"
    echo "===================================================="
    echo "请选择操作："
    echo "1) 安装 / 更新代理服务 (交互式)"
    echo "2) 卸载所有服务"
    echo "3) 退出"
    echo "----------------------------------------------------"

    read -rp "输入选项 (1/2/3): " CHOICE

    case "$CHOICE" in
        1)
            echo "----------------------------------------------------"
            echo "请选择要部署的协议："
            echo "1) TUIC v5"
            echo "2) Hysteria2"
            read -rp "输入选项 (1/2): " PROTOCOL_CHOICE
            
            if [ "$PROTOCOL_CHOICE" = "1" ]; then
                PROTOCOL="tuic"
            elif [ "$PROTOCOL_CHOICE" = "2" ]; then
                PROTOCOL="hysteria2"
            else
                echo "❌ 无效的选择，退出。"
                exit 1
            fi
            
            # 交互式模式下，需要先加载配置或读取端口
            mkdir -p "$SERVICE_DIR"
            if ! cd "$SERVICE_DIR"; then
                echo "❌ 无法进入服务目录: $SERVICE_DIR"
                exit 1
            fi
            
            install_dependencies
            
            if ! load_existing_config; then
                read_port "$@" # 读取端口 (使用 $1 参数为默认端口)
            else
                echo "⚠️ 检测到已有配置，端口/密码已加载。若需更改端口，请先卸载。"
            fi
            
            if [ "$PROTOCOL" = "tuic" ]; then
                deploy_tuic
            elif [ "$PROTOCOL" = "hysteria2" ]; then
                deploy_hysteria2
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

# ===================== 脚本主入口 =====================

main() {
    check_root
    
    # 使用 [ ] 替代 [[ ]] 增强兼容性
    if [ $# -ge 2 ] && { [ "$1" = "tuic" ] || [ "$1" = "hysteria2" ]; }; then
        # 模式 1: 一键安装/更新: <PROTOCOL> <PORT/RANGE>
        install_and_run_non_interactive "$1" "$2"
    elif [ $# -ge 1 ] && [ "$1" = "uninstall" ]; then
        # 模式 2: 一键卸载
        uninstall_service
    else
        # 模式 3: 交互式菜单
        main_menu "$@"
    fi
}

main "$@"
