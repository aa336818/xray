#!/usr/bin/env bash

# =========================================================
# System Check & Variables Setup
# =========================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

CONFIG_FILE="/usr/local/etc/xray/config.json"
PORT=8080
UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "19c6c3af-809f-4cd2-bbbb-9b1cf528cfc1")
XHTTP_PATH="/xhttp-tunnel"
DOMAIN=""
TUNNEL_TOKEN=""
BEST_DOMAIN="saas.sin.fan"  # 默认优选域名

ACTION=""

# 自动建立终端快捷指令: 输入 x 即可随时呼出脚本
SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || echo "$0")
if [[ -f "$SCRIPT_PATH" ]]; then
    ln -sf "$SCRIPT_PATH" /usr/local/bin/x 2>/dev/null || true
    chmod +x /usr/local/bin/x 2>/dev/null || true
fi

# =========================================================
# Parse Command Line Arguments
# =========================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --xray)
            ACTION="xray"
            shift
            ;;
        --tunnel)
            ACTION="tunnel"
            shift
            ;;
        --all)
            ACTION="all"
            shift
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        --uuid)
            UUID="$2"
            shift 2
            ;;
        --path)
            XHTTP_PATH="$2"
            shift 2
            ;;
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --best-domain)
            BEST_DOMAIN="$2"
            shift 2
            ;;
        --token)
            TUNNEL_TOKEN="$2"
            shift 2
            ;;
        --local-port)
            PORT="$2"
            shift 2
            ;;
        *)
            echo -e "${RED}未知参数: $1${PLAIN}"
            exit 1
            ;;
    esac
done

# =========================================================
# Helper & Installation Functions
# =========================================================
install_dependencies() {
    if command -v apt-get &>/dev/null; then
        apt-get update -y &>/dev/null && apt-get install -y curl wget jq tar systemd qrencode &>/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y curl wget jq tar systemd qrencode &>/dev/null
    fi
}

check_status() {
    # 检查 Xray 状态
    if systemctl is-active xray &>/dev/null; then
        XRAY_STATUS="${GREEN}[ 已安装并运行 ]${PLAIN}"
        if [[ -f "$CONFIG_FILE" ]]; then
            EX_PORT=$(jq -r '.inbounds[0].port // empty' "$CONFIG_FILE" 2>/dev/null)
            [[ -n "$EX_PORT" ]] && XRAY_STATUS="${GREEN}[ 已安装并运行 ]${PLAIN} (端口:${EX_PORT})"
        fi
    else
        XRAY_STATUS="${RED}[ 未安装 / 未运行 ]${PLAIN}"
    fi

    # 检查 Cloudflared 状态
    if systemctl is-active cloudflared &>/dev/null; then
        TUNNEL_STATUS="${GREEN}[ 已安装并运行 ]${PLAIN}"
    else
        TUNNEL_STATUS="${RED}[ 未安装 / 未运行 ]${PLAIN}"
    fi
}

install_xray_core() {
    echo -e "${YELLOW}开始安装/更新 Xray 内核...${PLAIN}"
    bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
    
    mkdir -p /usr/local/etc/xray
    cat <<EOF > /usr/local/etc/xray/config.json
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "${XHTTP_PATH}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF
    systemctl restart xray
    systemctl enable xray
    echo -e "${GREEN}Xray (VLESS + XHTTP) 配置成功！${PLAIN}"
}

install_cloudflared() {
    if [[ -z "$TUNNEL_TOKEN" ]]; then
        echo -e "${RED}错误: 安装 Argo 隧道必须提供 Token！${PLAIN}"
        exit 1
    fi

    echo -e "${YELLOW}开始安装 Cloudflare Tunnel (cloudflared)...${PLAIN}"
    
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  CF_ARCH="amd64" ;;
        aarch64) CF_ARCH="arm64" ;;
        armv7l)  CF_ARCH="arm" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
    esac

    wget -O /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
    chmod +x /usr/local/bin/cloudflared

    echo -e "${YELLOW}正在配置 Cloudflare 隧道服务...${PLAIN}"
    cloudflared service uninstall &>/dev/null || true
    cloudflared service install "${TUNNEL_TOKEN}"
    
    systemctl start cloudflared
    systemctl enable cloudflared
    echo -e "${GREEN}Cloudflare Argo 隧道安装并启动成功！${PLAIN}"
}

print_node_info() {
    if [[ -f "$CONFIG_FILE" ]]; then
        EX_UUID=$(jq -r '.inbounds[0].settings.clients[0].id // empty' "$CONFIG_FILE" 2>/dev/null)
        EX_PATH=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path // empty' "$CONFIG_FILE" 2>/dev/null)
        [[ -n "$EX_UUID" ]] && UUID="$EX_UUID"
        [[ -n "$EX_PATH" ]] && XHTTP_PATH="$EX_PATH"
    fi

    NODE_DOMAIN="${DOMAIN:-admin.com}"
    URL_PATH=$(echo "${XHTTP_PATH}" | sed 's/\//%2F/g')
    
    # 链接核心参数：Address 填写优选域名 saas.sin.fan，Host 和 SNI 填写你的 Tunnel 绑定域名
    VLESS_LINK="vless://${UUID}@${BEST_DOMAIN}:443?encryption=none&security=tls&type=xhttp&host=${NODE_DOMAIN}&path=${URL_PATH}&sni=${NODE_DOMAIN}#Argo-XHTTP-${NODE_DOMAIN}"

    echo -e "\n======================================================="
    echo -e "${GREEN}      🎉 节点配置信息如下 (使用优选域名加速)：${PLAIN}"
    echo -e "======================================================="
    echo -e "协议类型 (Protocol) : VLESS"
    echo -e "连接地址 (Address)  : ${BEST_DOMAIN}  ${YELLOW}(优选域名/节点)${PLAIN}"
    echo -e "端口 (Port)         : 443"
    echo -e "用户ID (UUID)       : ${UUID}"
    echo -e "传输协议 (Network)  : xhttp"
    echo -e "路径 (Path)         : ${XHTTP_PATH}"
    echo -e "传输层安全 (TLS)    : TLS (开启)"
    echo -e "伪装域名 (Host/SNI) : ${NODE_DOMAIN}"
    echo -e "-------------------------------------------------------"
    echo -e "${YELLOW}🔗 v2rayN / 小火箭 (Shadowrocket) 通用优选节点链接:${PLAIN}"
    echo -e "${GREEN}${VLESS_LINK}${PLAIN}"
    echo -e "-------------------------------------------------------"
    
    if command -v qrencode &>/dev/null; then
        echo -e "${YELLOW}📱 小火箭 (Shadowrocket) 扫码直接导入二维码:${PLAIN}\n"
        qrencode -t ansiutf8 "${VLESS_LINK}"
    fi
    echo -e "=======================================================\n"
}

uninstall_all() {
    echo -e "${YELLOW}正在清理并卸载服务...${PLAIN}"
    systemctl stop xray &>/dev/null || true
    systemctl disable xray &>/dev/null || true
    bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) --remove &>/dev/null || true
    rm -rf /usr/local/etc/xray

    systemctl stop cloudflared &>/dev/null || true
    cloudflared service uninstall &>/dev/null || true
    rm -f /usr/local/bin/cloudflared

    rm -f /usr/local/bin/x
    echo -e "${GREEN}所有服务、配置文件及快捷指令已彻底清理完毕！${PLAIN}"
}

# =========================================================
# Execution Control
# =========================================================
install_dependencies

case "$ACTION" in
    xray)
        install_xray_core
        print_node_info
        ;;
    tunnel)
        install_cloudflared
        ;;
    all)
        install_xray_core
        install_cloudflared
        print_node_info
        ;;
    *)
        check_status
        echo -e "\n======================================================="
        echo -e "   Custom XHTTP + Cloudflare Argo 隧道一键管理脚本"
        echo -e "======================================================="
        echo -e " Xray (VLESS-XHTTP) 运行状态 : ${XRAY_STATUS}"
        echo -e " Argo 隧道 (cloudflared) 状态: ${TUNNEL_STATUS}"
        echo -e "-------------------------------------------------------"
        echo -e " 1) 仅安装 Xray (VLESS + XHTTP)"
        echo -e " 2) 仅安装 Cloudflare 固定 Argo 隧道"
        echo -e " 3) 一键安装全部 (Xray + Argo 隧道)"
        echo -e " 4) 查看当前节点信息 (链接 & 二维码)"
        echo -e " 5) 卸载全部 (清理 Xray 与 Argo 隧道)"
        echo -e " 0) 退出"
        echo -e "======================================================="
        echo -e " 💡 快捷指令: 在终端直接输入 ${GREEN}x${PLAIN} 即可快捷呼出本面板"
        echo -e "=======================================================\n"
        read -p "请选择操作 [0-5]: " choice
        case "$choice" in
            1)
                read -p "请输入 Xray 本地监听端口 [默认: 8080]: " user_port
                PORT=${user_port:-8080}
                install_xray_core
                print_node_info
                ;;
            2)
                read -p "请输入 Cloudflare Tunnel Token: " TUNNEL_TOKEN
                read -p "请输入绑定的域名 (如 admin.com): " DOMAIN
                install_cloudflared
                ;;
            3)
                read -p "请输入 Xray 本地监听端口 [默认: 8080]: " user_port
                PORT=${user_port:-8080}
                read -p "请输入 Cloudflare Tunnel Token: " TUNNEL_TOKEN
                read -p "请输入绑定的域名 (如 admin.com): " DOMAIN
                read -p "请输入优选域名 [默认: saas.sin.fan]: " user_best
                BEST_DOMAIN=${user_best:-saas.sin.fan}
                install_xray_core
                install_cloudflared
                print_node_info
                ;;
            4)
                read -p "请输入绑定的域名 [默认: admin.com]: " user_domain
                DOMAIN=${user_domain:-admin.com}
                read -p "请输入优选域名 [默认: saas.sin.fan]: " user_best
                BEST_DOMAIN=${user_best:-saas.sin.fan}
                print_node_info
                ;;
            5)
                read -p "确定要卸载全部服务吗？[y/N]: " confirm
                if [[ "$confirm" == "y" \vert{}\vert{} "$confirm" == "Y" ]]; then
                    uninstall_all
                fi
                ;;
            *)
                exit 0
                ;;
        esac
        ;;
esac
