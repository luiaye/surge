#!/bin/bash
# =========================================
# Snell V5 + ShadowTLS V3 定制版
# 作者: luiaye
# =========================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 权限检查
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：请使用 root 运行${PLAIN}" && exit 1

# --- 系统网络优化 (TFO & BBR) ---
optimize_system() {
    echo -e "${CYAN}正在优化系统网络环境 (TFO & BBR)...${PLAIN}"
    # 开启 TFO
    sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null
    if ! grep -q "net.ipv4.tcp_fastopen = 3" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_fastopen = 3" >> /etc/sysctl.conf
    fi
    # 开启 BBR
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null
    fi
}

# --- 端口检查 ---
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
        STLS_URL="https://github.com/ihciah/shadow-tls/releases/download/v0.2.25/shadow-tls-x86_64-unknown-linux-musl"
        SNELL_URL="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip"
    elif [[ ${ARCH} == "aarch64" || ${ARCH} == "arm64" ]]; then
        STLS_URL="https://github.com/ihciah/shadow-tls/releases/download/v0.2.25/shadow-tls-aarch64-unknown-linux-musl"
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
    optimize_system

    echo -e "${CYAN}--- 端口配置 ---${PLAIN}"
    SNELL_PORT=$(check_and_set_port 33365 "Snell(后端)")
    STLS_PORT=$(check_and_set_port 443 "ShadowTLS(前端)")

    echo -e "${CYAN}正在下载二进制文件...${PLAIN}"
    wget -O /usr/local/bin/shadow-tls "${STLS_URL}" && chmod +x /usr/local/bin/shadow-tls
    wget -O snell.zip "${SNELL_URL}"
    unzip -o snell.zip && chmod +x snell-server && mv -f snell-server /usr/local/bin/snell-server && rm -f snell.zip

    # 配置 Snell 
    mkdir -p /etc/snell
    PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
    cat > /etc/snell/config.conf << EOF
[snell-server]
listen = 0.0.0.0:${SNELL_PORT}
psk = ${PSK}
ipv6 = true
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

    # 配置 ShadowTLS 
    PW=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
    cat > /etc/systemd/system/shadowtls.service << EOF
[Unit]
Description=ShadowTLS Service
After=network.target snell.service
[Service]
ExecStart=/usr/local/bin/shadow-tls --v3 server --listen [::]:${STLS_PORT} --server 127.0.0.1:${SNELL_PORT} --tls www.microsoft.com:443 --password ${PW}
Restart=always
AmbientCapabilities=CAP_NET_BIND_SERVICE
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl enable --now snell shadowtls
    
    IP4=$(curl -s4 icanhazip.com || echo "None")
    IP6=$(curl -s6 icanhazip.com || echo "None")

    clear
    echo -e "${GREEN}==================================================${PLAIN}"
    echo -e "${GREEN}安装成功！${PLAIN}"
    echo -e "--------------------------------------------------"
    
    echo -e "${CYAN}1. Surge 配置 (Shadow-TLS V3 + TFO + Reuse)${PLAIN}"

    [[ "$IP4" != "None" ]] && echo -e "IPv4: $(hostname)_4 = snell, ${IP4}, ${STLS_PORT}, psk = ${PSK}, version = 5, reuse = true, tfo = true, shadow-tls-password = ${PW}, shadow-tls-sni = www.microsoft.com, shadow-tls-version = 3"
    [[ "$IP6" != "None" ]] && echo -e "IPv6: $(hostname)_6 = snell, [${IP6}], ${STLS_PORT}, psk = ${PSK}, version = 5, reuse = true, tfo = true, shadow-tls-password = ${PW}, shadow-tls-sni = www.microsoft.com, shadow-tls-version = 3"
    
    echo -e "\n${CYAN}2. 纯 Snell 模式 (直连 + TFO + Reuse)${PLAIN}"
    [[ "$IP4" != "None" ]] && echo -e "IPv4: $(hostname)_Snell4 = snell, ${IP4}, ${SNELL_PORT}, psk = ${PSK}, version = 5, reuse = true, tfo = true"
    [[ "$IP6" != "None" ]] && echo -e "IPv6: $(hostname)_Snell6 = snell, [${IP6}], ${SNELL_PORT}, psk = ${PSK}, version = 5, reuse = true, tfo = true"
    echo -e "${GREEN}==================================================${PLAIN}"
}

# --- 菜单循环 ---
while true; do
    echo -e "\n${CYAN}--- ShadowTLS V3 & Snell V5 定制脚本 ---${PLAIN}"
    echo -e "${GREEN}1)${PLAIN} 安装"
    echo -e "${RED}2)${PLAIN} 彻底卸载"
    echo -e "${YELLOW}0)${PLAIN} 退出脚本"
    read -p "请输入选项 [0-2]: " opt
    case $opt in
        1) install; break ;;
        2) uninstall; break ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${PLAIN}" ;;
    esac
done
