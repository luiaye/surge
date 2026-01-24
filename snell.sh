#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：请使用 root 权限运行此脚本。${PLAIN}" && exit 1

# --- 卸载函数 ---
uninstall_all() {
    echo -e "${YELLOW}正在清理服务和残留文件...${PLAIN}"
    systemctl stop shadowtls snell >/dev/null 2>&1
    systemctl disable shadowtls snell >/dev/null 2>&1
    
    # 彻底删除二进制和配置
    rm -f /usr/local/bin/shadow-tls /usr/local/bin/snell-server
    rm -rf /etc/snell
    rm -f /etc/systemd/system/shadowtls.service
    rm -f /etc/systemd/system/snell.service
    rm -f /usr/local/bin/stls  # 清理旧版冗余脚本
    
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成！所有服务已移除。${PLAIN}"
}

# --- 安装函数 ---
install_all() {
    echo -e "${CYAN}正在初始化环境...${PLAIN}"
    apt update && apt install -y wget unzip curl jq
    
    # 清理可能存在的旧进程
    pkill -9 shadow-tls >/dev/null 2>&1
    pkill -9 snell-server >/dev/null 2>&1

    # 1. 下载 ShadowTLS (v0.2.25 musl)
    echo -e "${CYAN}正在下载 ShadowTLS...${PLAIN}"
    wget -O /usr/local/bin/shadow-tls "https://github.moeyy.xyz/https://github.com/ihciah/shadow-tls/releases/download/v0.2.25/shadow-tls-x86_64-unknown-linux-musl"
    if [ ! -s /usr/local/bin/shadow-tls ]; then
        wget -O /usr/local/bin/shadow-tls "https://github.com/ihciah/shadow-tls/releases/download/v0.2.25/shadow-tls-x86_64-unknown-linux-musl"
    fi
    chmod +x /usr/local/bin/shadow-tls

    # 2. 下载 Snell V5
    echo -e "${CYAN}正在下载 Snell V5...${PLAIN}"
    wget -O snell.zip "https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip"
    unzip -o snell.zip && chmod +x snell-server && mv -f snell-server /usr/local/bin/snell-server
    rm -f snell.zip

    # 3. 配置 Snell (监听 127.0.0.1)
    mkdir -p /etc/snell
    SNELL_PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
    cat > /etc/snell/config.conf << EOF
[snell-server]
listen = 127.0.0.1:33366
ipv6 = false
psk = ${SNELL_PSK}
obfs = off
tfo = true
version = 5
EOF

    cat > /etc/systemd/system/snell.service << EOF
[Unit]
Description=Snell Service
After=network.target

[Service]
ExecStart=/usr/local/bin/snell-server -c /etc/snell/config.conf
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    # 4. 配置 ShadowTLS (443 端口)
    STLS_PW=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
    cat > /etc/systemd/system/shadowtls.service << EOF
[Unit]
Description=ShadowTLS Service
After=network.target snell.service

[Service]
Type=simple
ExecStart=/usr/local/bin/shadow-tls server --listen 0.0.0.0:443 --server 127.0.0.1:33366 --tls icloud.com:443 --password ${STLS_PW}
Restart=always
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    # 5. 启动
    systemctl daemon-reload
    systemctl enable snell shadowtls
    systemctl restart snell shadowtls

    # 6. 展示结果
    IP=$(curl -s4 ipinfo.io/ip)
    clear
    echo -e "${GREEN}==================================================${PLAIN}"
    echo -e "${GREEN}部署完成！ShadowTLS 已成功联动 Snell V5。${PLAIN}"
    echo -e "--------------------------------------------------"
    echo -e "Snell PSK: ${YELLOW}${SNELL_PSK}${PLAIN}"
    echo -e "STLS 密码: ${YELLOW}${STLS_PW}${PLAIN}"
    echo -e "--------------------------------------------------"
    echo -e "${CYAN}Surge 配置行：${PLAIN}"
    echo -e "$(hostname) = snell, ${IP}, 443, psk=${SNELL_PSK}, version=5, tfo=true, shadow-tls-password=${STLS_PW}, shadow-tls-sni=icloud.com"
    echo -e "${GREEN}==================================================${PLAIN}"
    echo -e "管理命令: systemctl status shadowtls"
}

# --- 菜单 ---
clear
echo -e "${CYAN}--- ShadowTLS & Snell V5 管理脚本 ---${PLAIN}"
echo -e "${GREEN}1.${PLAIN} 安装/覆盖安装"
echo -e "${RED}2.${PLAIN} 彻底卸载"
echo -e "0. 退出"
read -p "请选择: " choice

case $choice in
    1) install_all ;;
    2) uninstall_all ;;
    *) exit 0 ;;
esac
