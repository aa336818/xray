#!/bin/bash

# ==========================================
#  自定义配置项
# ==========================================
SHORTCUT_NAME="xxx"  # 快捷指令名称（可自定义修改为 xxx、xray 等）

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    echo "❌ 请使用 root 权限运行此脚本！"
    exit 1
fi

# 自动创建快捷指令
create_shortcut() {
    CURRENT_PATH=$(readlink -f "$0")
    if [ "$CURRENT_PATH" != "/usr/local/bin/$SHORTCUT_NAME" ]; then
        cp "$CURRENT_PATH" "/usr/local/bin/$SHORTCUT_NAME"
        chmod +x "/usr/local/bin/$SHORTCUT_NAME"
    fi
}

# 安装基础依赖
install_dependencies() {
    echo "🌐 正在更新软件包并安装必要依赖..."
    if command -v apt-get &>/dev/null; then
        apt-get update -y && apt-get install -y curl wget jq openssl tar
    elif command -v yum &>/dev/null; then
        yum update -y && yum install -y curl wget jq openssl tar
    fi
}

# 安装/更新 Xray 官方核心
install_xray() {
    echo "🚀 正在安装/更新 Xray 核心..."
    bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
}

# 获取本机公网 IP
get_public_ip() {
    PUB_IP=$(curl -s https://api.ipify.org || curl -s https://ipv4.icanhazip.com)
}

# 安装并启动 Cloudflare Argo Tunnel
setup_argo() {
    local local_port=$1
    local argo_input=$2

    echo "📦 正在下载并配置 Cloudflare Tunnel (cloudflared)..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) CF_ARCH="amd64" ;;
        aarch64) CF_ARCH="arm64" ;;
        *) echo "❌ 不支持的架构: $ARCH"; exit 1 ;;
    esac
    
    curl -L -o /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
    chmod +x /usr/local/bin/cloudflared

    systemctl stop cloudflared &>/dev/null
    cloudflared service uninstall &>/dev/null

    if [ -n "$argo_input" ]; then
        if [[ "$argo_input" == eyJ* ]]; then
            # 检测到输入 Token，追加询问在 Cloudflare 上绑定的固定域名
            echo ""
            read -p "📌 检测到输入的是 Token，请输入你在 CF 后台为该 Tunnel 绑定的固定域名: " REAL_DOMAIN
            cloudflared service install "$argo_input"
            systemctl start cloudflared
            systemctl enable cloudflared
            ARGO_DOMAIN="${REAL_DOMAIN:-saas.sin.fan}"
        else
            ARGO_DOMAIN="$argo_input"
        fi
    else
        echo "⚡ 未输入 Token，启动 Argo Quick Tunnel 快速隧道..."
        nohup cloudflared tunnel --url http://127.0.0.1:$local_port > /tmp/argo.log 2>&1 &
        sleep 5
        ARGO_DOMAIN=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' /tmp/argo.log | head -n 1 | sed 's/https:\/\///')
    fi
}

# 保存节点信息文件
save_node_info() {
    local content="$1"
    mkdir -p /usr/local/etc/xray
    echo "$content" > /usr/local/etc/xray/node_info.txt
}

# 模式 1：单安装 XHTTP + Argo
install_xhttp_argo() {
    install_dependencies
    install_xray
    
    echo ""
    echo "=========================================="
    echo "   配置 Mode 1: Xray (XHTTP) + Argo Tunnel"
    echo "=========================================="
    
    UUID=$(/usr/local/bin/xray uuid)
    XHTTP_PATH="/xhttp-$(openssl rand -hex 4)"
    LOCAL_PORT=8080

    read -p "请输入你的 Argo 域名或 Token (留空将启动临时 Quick Tunnel 隧道): " ARGO_INPUT

    cat <<EOF > /usr/local/etc/xray/config.json
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": $LOCAL_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": { "path": "$XHTTP_PATH" }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

    systemctl restart xray
    systemctl enable xray
    setup_argo $LOCAL_PORT "$ARGO_INPUT"

    NODE_DOMAIN="${ARGO_DOMAIN:-saas.sin.fan}"
    VLESS_LINK="vless://${UUID}@${NODE_DOMAIN}:443?security=tls&encryption=none&type=xhttp&path=${XHTTP_PATH}&host=${NODE_DOMAIN}&sni=${NODE_DOMAIN}#Argo-XHTTP-Node"

    INFO_TEXT="==================================================
  ✅ Xray (XHTTP) + Argo 节点信息
==================================================
通用 UUID   : $UUID
Argo 域名   : ${NODE_DOMAIN}
XHTTP Path  : ${XHTTP_PATH}
--------------------------------------------------
📋 VLESS 节点链接:
$VLESS_LINK
=================================================="

    save_node_info "$INFO_TEXT"
    echo ""
    echo "$INFO_TEXT"
    echo ""
    echo "💡 快捷键是：[ $SHORTCUT_NAME ] (在终端直接输入即可直达菜单)"
}

# 模式 2：单安装 VLESS-REALITY
install_reality() {
    install_dependencies
    install_xray
    get_public_ip

    echo ""
    echo "=========================================="
    echo "   配置 Mode 2: Xray + VLESS-REALITY 直连"
    echo "=========================================="

    read -p "请输入 REALITY 伪装域名 SNI (默认: www.microsoft.com): " CUSTOM_SNI
    SNI=${CUSTOM_SNI:-"www.microsoft.com"}

    read -p "请输入监听端口 (默认: 443，有宝塔建议填 8443): " CUSTOM_PORT
    PORT=${CUSTOM_PORT:-443}

    UUID=$(/usr/local/bin/xray uuid)
    KEYPAIR=$(/usr/local/bin/xray x25519)
    PRIV_KEY=$(echo "$KEYPAIR" | grep "Private key" | awk '{print $3}')
    PUB_KEY=$(echo "$KEYPAIR" | grep "Public key" | awk '{print $3}')
    SHORT_ID=$(openssl rand -hex 4)

    cat <<EOF > /usr/local/etc/xray/config.json
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$SNI:443",
          "xver": 0,
          "serverNames": ["$SNI"],
          "privateKey": "$PRIV_KEY",
          "shortIds": ["$SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

    systemctl restart xray
    systemctl enable xray

    REALITY_LINK="vless://${UUID}@${PUB_IP}:${PORT}?security=reality&encryption=none&pbk=${PUB_KEY}&headerType=none&type=tcp&flow=xtls-rprx-vision&sni=${SNI}&sid=${SHORT_ID}#REALITY-${SNI}"

    INFO_TEXT="==================================================
  ✅ Xray VLESS-REALITY 节点信息
==================================================
通用 UUID   : $UUID
服务器 IP   : $PUB_IP
端口        : $PORT
伪装 SNI    : $SNI
Public Key  : $PUB_KEY
Short ID    : $SHORT_ID
--------------------------------------------------
📋 REALITY 节点链接:
$REALITY_LINK
=================================================="

    save_node_info "$INFO_TEXT"
    echo ""
    echo "$INFO_TEXT"
    echo ""
    echo "💡 快捷键是：[ $SHORTCUT_NAME ] (在终端直接输入即可直达菜单)"
}

# 模式 3：双通道同时安装 (XHTTP + Argo AND REALITY)
install_both() {
    install_dependencies
    install_xray
    get_public_ip

    echo ""
    echo "=========================================="
    echo "   配置 Mode 3: 同时安装 XHTTP+Argo 与 REALITY"
    echo "=========================================="

    read -p "1/3 请输入你的 Argo 域名或 Token (留空启动临时 Quick Tunnel): " ARGO_INPUT
    read -p "2/3 请输入 REALITY 伪装域名 SNI (默认: www.microsoft.com): " CUSTOM_SNI
    SNI=${CUSTOM_SNI:-"www.microsoft.com"}

    read -p "3/3 请输入 REALITY 直连监听端口 (默认: 443，有宝塔建议填 8443): " CUSTOM_PORT
    PORT=${CUSTOM_PORT:-443}

    UUID=$(/usr/local/bin/xray uuid)
    XHTTP_PATH="/xhttp-$(openssl rand -hex 4)"
    LOCAL_PORT=8080

    KEYPAIR=$(/usr/local/bin/xray x25519)
    PRIV_KEY=$(echo "$KEYPAIR" | grep "Private key" | awk '{print $3}')
    PUB_KEY=$(echo "$KEYPAIR" | grep "Public key" | awk '{print $3}')
    SHORT_ID=$(openssl rand -hex 4)

    cat <<EOF > /usr/local/etc/xray/config.json
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": $LOCAL_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": { "path": "$XHTTP_PATH" }
      }
    },
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$SNI:443",
          "xver": 0,
          "serverNames": ["$SNI"],
          "privateKey": "$PRIV_KEY",
          "shortIds": ["$SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

    systemctl restart xray
    systemctl enable xray
    setup_argo $LOCAL_PORT "$ARGO_INPUT"

    NODE_DOMAIN="${ARGO_DOMAIN:-saas.sin.fan}"
    XHTTP_LINK="vless://${UUID}@${NODE_DOMAIN}:443?security=tls&encryption=none&type=xhttp&path=${XHTTP_PATH}&host=${NODE_DOMAIN}&sni=${NODE_DOMAIN}#Argo-XHTTP"
    REALITY_LINK="vless://${UUID}@${PUB_IP}:${PORT}?security=reality&encryption=none&pbk=${PUB_KEY}&headerType=none&type=tcp&flow=xtls-rprx-vision&sni=${SNI}&sid=${SHORT_ID}#REALITY-${SNI}"

    INFO_TEXT="==================================================
 🎉🎉🎉 双组合协议部署完成！节点信息如下： 🎉🎉🎉
==================================================
【通用 UUID】: $UUID
--------------------------------------------------
🔗 节点 1：Argo + XHTTP 隧道节点
Argo 域名 : ${NODE_DOMAIN}
XHTTP Path: ${XHTTP_PATH}
节点链接  :
$XHTTP_LINK
--------------------------------------------------
🔗 节点 2：VLESS-REALITY 原生直连节点
服务器 IP : $PUB_IP
端口      : $PORT
伪装 SNI  : $SNI
Public Key: $PUB_KEY
Short ID  : $SHORT_ID
节点链接  :
$REALITY_LINK
=================================================="

    save_node_info "$INFO_TEXT"
    echo ""
    echo "$INFO_TEXT"
    echo ""
    echo "💡 快捷键是：[ $SHORTCUT_NAME ] (在终端直接输入即可直达菜单)"
}

# 模式 4：查看当前节点信息
view_info() {
    echo ""
    if [ -f "/usr/local/etc/xray/node_info.txt" ]; then
        cat /usr/local/etc/xray/node_info.txt
    else
        echo "❌ 未找到已保存的节点信息！可能尚未安装任何协议。"
    fi
    echo ""
    echo "💡 快捷键是：[ $SHORTCUT_NAME ] (在终端直接输入即可直达菜单)"
}

# 模式 5：卸载全部
uninstall_all() {
    echo ""
    read -p "❓ 确定要卸载 Xray、Argo 及所有配置文件吗？(y/n): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "🗑️  正在停止并清理服务..."
        
        systemctl stop xray cloudflared &>/dev/null
        systemctl disable xray cloudflared &>/dev/null

        cloudflared service uninstall &>/dev/null
        rm -f /usr/local/bin/cloudflared
        rm -f /tmp/argo.log

        bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) --remove &>/dev/null
        rm -rf /usr/local/etc/xray
        rm -f "/usr/local/bin/$SHORTCUT_NAME"

        echo "✅ 所有相关组件与配置文件已完全卸载！"
    else
        echo "❌ 已取消卸载操作。"
    fi
}

# 初始化快捷指令
create_shortcut

# 主菜单交互
clear
echo "=========================================="
echo "      Xray 多协议一键集成部署脚本"
echo "=========================================="
echo " 1. 单独安装 Xray (XHTTP) + Cloudflare Argo 隧道"
echo " 2. 单独安装 Xray + VLESS-REALITY 直连"
echo " 3. 同时安装两种协议 (XHTTP+Argo + REALITY，共享核心)"
echo " 4. 查看节点信息"
echo " 5. 卸载全部"
echo " 6. 退出"
echo "=========================================="
echo "💡 快捷键是：[ $SHORTCUT_NAME ] (在终端直接输入即可直达菜单)"
echo "=========================================="
read -p "请输入选项 [1-6]: " CHOICE

case "$CHOICE" in
    1) install_xhttp_argo ;;
    2) install_reality ;;
    3) install_both ;;
    4) view_info ;;
    5) uninstall_all ;;
    6) exit 0 ;;
    *) echo "❌ 无效选项！"; exit 1 ;;
esac
