#!/bin/bash
# =========================================
# Snell V5 + ShadowTLS V3 定制修复版
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

# --- 系统网络优化 ---
optimize_system() {
    echo -e "${CYAN}正在优化系统网络环境 (TFO & BBR)...${PLAIN}"
    sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null
    if ! grep -q "net.ipv4.tcp_fastopen = 3" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_fastopen = 3" >> /etc/sysctl.conf
    fi
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null
    fi
}

# --- 显示现有配置函数 ---
show_config() {
    if [[ ! -f /etc/snell/config.conf ]] || [[ ! -f /etc/systemd/system/shadowtls.service ]]; then
        echo -e "${RED}错误：未检测到已安装的服务配置。${PLAIN}"
        return
    fi

    echo -e "${CYAN}正在读取现有配置并检测 IP...${PLAIN}"
    
    # 提取 Snell 配置
    SNELL_PORT=$(grep 'listen =' /etc/snell/config.conf | cut -d: -f2)
    PSK=$(grep 'psk =' /etc/snell/config.conf | awk '{print $3}')
    
    # 提取 ShadowTLS 配置
    STLS_PORT=$(grep 'ExecStart=' /etc/systemd/system/shadowtls.service | sed 's/.*: \?\([0-9]*\).*/\1/')
    # 兼容带中括号的提取
    [[ -z $STLS_PORT ]] && STLS_PORT=$(grep 'ExecStart=' /etc/systemd/system/shadowtls.service | sed 's/.*\]:\([0-9]*\).*/\1/')
    PW=$(grep 'ExecStart=' /etc/systemd/system/shadowtls.service | sed 's/.*--password \([^ ]*\).*/\1/')
    SNI=$(grep 'ExecStart=' /etc/systemd/system/shadowtls.service | sed 's/.*--tls \([^:]*\).*/\1/')

    IP4=$(curl -s4 icanhazip.com || echo "None")
    IP6=$(curl -s6 icanhazip.com || echo "None")

    echo -e "${GREEN}==================================================${PLAIN}"
    echo -e "${GREEN}当前运行中的配置信息：${PLAIN}"
    echo -e "--------------------------------------------------"
    
    echo -e "${CYAN}1. Surge 配置 (Shadow-TLS V3 + TFO + Reuse)${PLAIN}"
    [[ "$IP4" != "None" ]] && echo -e "IPv4: $(hostname)_4 = snell, ${IP4}, ${STLS_PORT}, psk = ${PSK}, version = 5, reuse = true, tfo = true, shadow-tls-password = ${PW}, shadow-tls-sni = ${SNI}, shadow-tls-version = 3"
    [[ "$IP6" != "None" ]] && echo -e "IPv6: $(hostname)_6 = snell, [${IP6}], ${STLS_PORT}, psk = ${PSK}, version = 5, reuse = true, tfo = true, shadow-tls-password = ${PW}, shadow-tls-sni = ${SNI}, shadow-tls-version = 3"
    
    echo -e "\n${CYAN}2. 纯 Snell 模式 (直连 + TFO + Reuse)${PLAIN}"
    [[ "$IP4" != "None" ]] && echo -e "IPv4: $(hostname)_Snell4 = snell, ${IP4}, ${SNELL_PORT}, psk = ${PSK}, version = 5, reuse = true, tfo = true"
    [[ "$IP6" != "None" ]] && echo -e "IPv6: $(hostname)_Snell6 = snell, [${IP6}], ${SNELL_PORT}, psk = ${PSK}, version = 5, reuse = true, tfo = true"
    echo -e "${GREEN}==================================================${PLAIN}"
}

# --- 其他安装/卸载逻辑  ---
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

install() {
    apt update && apt install -y wget unzip curl
    detect_arch
    optimize_system
    SNELL_PORT=$(ss -lntup | grep -q ":33365 " && echo 33366 || echo 33365)
    STLS_PORT=443
    wget -O /usr/local/bin/shadow-tls "${STLS_URL}" && chmod +x /usr/local/bin/shadow-tls
    wget -O snell.zip "${SNELL_URL}"
    unzip -o snell.zip && chmod +x snell-server && mv -f snell-server /usr/local/bin/snell-server && rm -f snell.zip
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
    show_config
}

# --- 菜单循环 ---
while true; do
    echo -e "\n${CYAN}--- ShadowTLS V3 & Snell V5 定制脚本 ---${PLAIN}"
    echo -e "${GREEN}1)${PLAIN} 安装"
    echo -e "${GREEN}2)${PLAIN} 显示当前配置"
    echo -e "${RED}3)${PLAIN} 彻底卸载"
    echo -e "${YELLOW}0)${PLAIN} 退出脚本"
    read -p "请输入选项 [0-3]: " opt
    case $opt in
        1) install ;;
        2) show_config ;;
        3) uninstall ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${PLAIN}" ;;
    esac
done
