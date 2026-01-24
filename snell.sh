#!/bin/bash
# =========================================
# Snell V5 + ShadowTLS 定制版
# 作者: luiaye
# =========================================
# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：请使用 root 运行${PLAIN}" && exit 1

# --- 端口检查与手动输入函数 ---
check_and_set_port() {
    local default_port=$1
    local port_name=$2
    local final_port=$default_port

    while true; do
        if ss -lntup | grep -q ":${final_port} "; then
            echo -e "${YELLOW}[!] 警告: ${port_name}端口 ${final_port} 已被占用。${PLAIN}"
            read -p "请输入一个新的${port_name}端口: " final_port
        else
            break
        fi
    done
    echo $final_port
}

# --- 架构适配 ---
detect_arch() {
    ARCH=$(uname -m)
    if [[ ${ARCH} == "x86_64" ]]; then
        STLS_URL="https://github.moeyy.xyz/https://github.com/ihciah/shadow-tls/releases/download/v0.2.25/shadow-tls-x86_64-unknown-linux-musl"
        SNELL_URL="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip"
    elif [[ ${ARCH} == "aarch64" || ${ARCH} == "arm64" ]]; then
        STLS_URL="https://github.moeyy.xyz/https://github.com/ihciah/shadow-tls/releases/download/v0.2.25/shadow-tls-aarch64-unknown-linux-musl"
        SNELL_URL="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-aarch64.zip"
    else
        echo -e "${RED}不支持的架构${PLAIN}"; exit 1
    fi
}

# --- 卸载逻辑 ---
uninstall() {
    echo -e "${YELLOW}正在彻底卸载服务...${PLAIN}"
    systemctl stop shadowtls snell >/dev/null 2>&1
    systemctl disable shadowtls snell >/dev/null 2>&1
    rm -f /usr/local/bin/shadow-tls /usr/local/bin/snell-server
    rm -rf /etc/snell
    rm -f /etc/systemd/system/shadowtls.service /etc/systemd/system/snell.service
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成！${PLAIN}"
}

# --- 安装逻辑 ---
install() {
    apt update && apt install -y wget unzip curl
    detect_arch

    # 1. 端口确认
    echo -e "${CYAN}--- 端口配置 ---${PLAIN}"
    SNELL_PORT=$(check_and_set_port 33366 "Snell(后端)")
    STLS_PORT=$(check_and_set_port 443 "ShadowTLS(前端)")

    # 2. 下载
    wget -O /usr/local/bin/shadow-tls "${STLS_URL}" || wget -O /usr/local/bin/shadow-tls "https://github.com/ihciah/shadow-tls/releases/download/v0.2.25/$(basename ${STLS_URL})"
    chmod +x /usr/local/bin/shadow-tls
    wget -O snell.zip "${SNELL_URL}"
    unzip -o snell.zip && chmod +x snell-server && mv -f snell-server /usr/local/bin/snell-server
    rm -f snell.zip

    # 3. 配置 Snell
    mkdir -p /etc/snell
    PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
    cat > /etc/snell/config.conf << EOF
[snell-server]
listen = 0.0.0.0:${SNELL_PORT}
psk = ${PSK}
ipv6 = false
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
[Install]
WantedBy=multi-user.target
EOF

    # 4. 配置 ShadowTLS
    PW=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
    cat > /etc/systemd/system/shadowtls.service << EOF
[Unit]
Description=ShadowTLS Service
After=network.target snell.service
[Service]
ExecStart=/usr/local/bin/shadow-tls server --listen 0.0.0.0:${STLS_PORT} --server 127.0.0.1:${SNELL_PORT} --tls icloud.com:443 --password ${PW}
Restart=always
AmbientCapabilities=CAP_NET_BIND_SERVICE
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl enable --now snell shadowtls
    
    IP=$(curl -s4 ipinfo.io/ip)
    clear
    echo -e "${GREEN}==================================================${PLAIN}"
    echo -e "${GREEN}安装成功！已适配您的 CPU 架构。${PLAIN}"
    echo -e "--------------------------------------------------"
    echo -e "Snell PSK: ${YELLOW}${PSK}${PLAIN}"
    echo -e "ShadowTLS 密码: ${YELLOW}${PW}${PLAIN}"
    echo -e "--------------------------------------------------"
    echo -e "${CYAN}1. Surge 配置 (Shadow-TLS 模式 - 端口:${STLS_PORT})${PLAIN}"
    echo -e "$(hostname)_STLS = snell, ${IP}, ${STLS_PORT}, psk=${PSK}, version=5, tfo=true, shadow-tls-password=${PW}, shadow-tls-sni=icloud.com"
    echo -e ""
    echo -e "${CYAN}2. Surge 配置 (纯 Snell 模式 - 端口:${SNELL_PORT})${PLAIN}"
    echo -e "$(hostname)_Snell = snell, ${IP}, ${SNELL_PORT}, psk=${PSK}, version=5, tfo=true"
    echo -e "${GREEN}==================================================${PLAIN}"
}

# --- 菜单循环 ---
while true; do
    echo -e "\n${CYAN}--- ShadowTLS & Snell V5 全能管理脚本 ---${PLAIN}"
    echo -e "${GREEN}1)${PLAIN} 安装"
    echo -e "${RED}2)${PLAIN} 彻底卸载"
    echo -e "${YELLOW}0)${PLAIN} 退出脚本"
    echo -e "------------------------------------"
    read -p "请输入选项 [0-2]: " opt
    
    case $opt in
        1) install; break ;;
        2) uninstall; break ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${PLAIN}" ;;
    esac
done
