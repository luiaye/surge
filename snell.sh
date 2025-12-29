#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

#=================================================
#   System Required: CentOS/Debian/Ubuntu
#   Description: Snell Server 管理脚本（精简版：仅官方源）
#   Based on: luiaye
#=================================================

sh_ver="1.0.0-min"
snell_v4_version="4.1.1"
snell_v5_version="5.0.1"

snell_dir="/etc/snell/"
snell_bin="/usr/local/bin/snell-server"
snell_conf="/etc/snell/config.conf"
snell_version_file="/etc/snell/ver.txt"
sysctl_conf="/etc/sysctl.d/99-snell.conf"

Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Green_background_prefix="\033[42;37m" && Red_background_prefix="\033[41;37m" && Font_color_suffix="\033[0m" && Yellow_font_prefix="\033[0;33m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Tip="${Yellow_font_prefix}[注意]${Font_color_suffix}"

#========================
# 基础检查
#========================
checkRoot(){
  [[ $EUID != 0 ]] && echo -e "${Error} 当前非ROOT账号(或没有ROOT权限)，无法继续操作，请更换ROOT账号或使用 ${Green_background_prefix}sudo su${Font_color_suffix} 获取临时ROOT权限。" && exit 1
}

checkSys(){
  if [[ -f /etc/redhat-release ]]; then
    release="centos"
  elif cat /etc/issue | grep -q -E -i "debian"; then
    release="debian"
  elif cat /etc/issue | grep -q -E -i "ubuntu"; then
    release="ubuntu"
  elif cat /proc/version | grep -q -E -i "debian"; then
    release="debian"
  elif cat /proc/version | grep -q -E -i "ubuntu"; then
    release="ubuntu"
  elif cat /proc/version | grep -q -E -i "centos|red hat|redhat"; then
    release="centos"
  fi
}

sysArch() {
  uname=$(uname -m)
  if [[ "$uname" == "i686" ]] || [[ "$uname" == "i386" ]]; then
    arch="i386"
  elif [[ "$uname" == *"armv7"* ]] || [[ "$uname" == "armv6l" ]]; then
    arch="armv7l"
  elif [[ "$uname" == *"armv8"* ]] || [[ "$uname" == "aarch64" ]]; then
    arch="aarch64"
  else
    arch="amd64"
  fi
}

checkDependencies(){
  local deps=("wget" "unzip" "ss" "curl")
  for cmd in "${deps[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
      echo -e "${Error} 缺少依赖: $cmd，正在尝试安装..."
      if [[ -f /etc/debian_version ]]; then
        apt-get update && apt-get install -y "$cmd"
      elif [[ -f /etc/redhat-release ]]; then
        yum install -y "$cmd"
      else
        echo -e "${Error} 不支持的系统，无法自动安装 $cmd"
        exit 1
      fi
    fi
  done
  echo -e "${Info} 依赖检查完成"
}

installDependencies(){
  if [[ ${release} == "centos" ]]; then
    yum update -y
    yum install gzip wget curl unzip jq -y
  else
    apt-get update -y
    apt-get install gzip wget curl unzip jq -y
  fi
  sysctl -w net.core.rmem_max=26214400 >/dev/null 2>&1
  sysctl -w net.core.rmem_default=26214400 >/dev/null 2>&1
  # 如不希望脚本修改时区，可注释下一行：
  \cp -f /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
  echo -e "${Info} 依赖安装完成"
}

#========================
# 网络优化（可选）
#========================
enableTCPFastOpen() {
  kernel=$(uname -r | awk -F . '{print $1}')
  if [ "$kernel" -ge 3 ]; then
    echo 3 >/proc/sys/net/ipv4/tcp_fastopen
    cat > "$sysctl_conf" << EOF
# Snell Server 网络优化配置
# 由 Snell 管理脚本自动生成

fs.file-max = 6815744
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 1048576 33554432
net.ipv4.tcp_wmem = 4096 1048576 33554432
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_metrics_save = 0
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_frto = 2
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1

# BBR 拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system >/dev/null 2>&1
    echo -e "${Info} TCP Fast Open 和网络优化配置已启用！"
  else
    echo -e "${Error} 系统内核版本过低，无法支持 TCP Fast Open！"
  fi
}

#========================
# Snell 安装/下载
#========================
checkInstalledStatus(){
  [[ ! -e ${snell_bin} ]] && echo -e "${Error} Snell Server 没有安装，请检查！" && exit 1
}

checkStatus(){
  if systemctl is-active snell-server.service &> /dev/null; then
    status="running"
  else
    status="stopped"
  fi
}

getSnellDownloadUrl(){
  sysArch
  local version=$1
  snell_url="https://dl.nssurge.com/snell/snell-server-v${version}-linux-${arch}.zip"
}

downloadSnell(){
  local version=$1
  local version_type=$2

  echo -e "${Info} 试图请求 ${Yellow_font_prefix}${version_type}${Font_color_suffix} Snell Server ……"
  getSnellDownloadUrl "${version}"

  if ! curl -I -s --max-time 10 "$snell_url" | head -1 | grep -q "200"; then
    echo -e "${Error} Snell Server ${Yellow_font_prefix}${version_type}${Font_color_suffix} 下载链接不可用！"
    return 1
  fi

  wget -N "${snell_url}"
  if [[ ! -e "snell-server-v${version}-linux-${arch}.zip" ]]; then
    echo -e "${Error} Snell Server ${Yellow_font_prefix}${version_type}${Font_color_suffix} 下载失败！"
    return 1
  else
    unzip -o "snell-server-v${version}-linux-${arch}.zip" >/dev/null 2>&1
  fi

  if [[ ! -e "snell-server" ]]; then
    echo -e "${Error} Snell Server ${Yellow_font_prefix}${version_type}${Font_color_suffix} 解压失败！"
    return 1
  else
    rm -rf "snell-server-v${version}-linux-${arch}.zip"
    chmod +x snell-server
    mv -f snell-server "${snell_bin}"
    echo "v${version}" > "${snell_version_file}"
    echo -e "${Info} Snell Server 主程序下载安装完毕！"
    return 0
  fi
}

downloadSnellV4(){ downloadSnell "${snell_v4_version}" "v4 官网源版"; }
downloadSnellV5(){ downloadSnell "${snell_v5_version}" "v5 官网源版"; }

#========================
# systemd 服务
#========================
setupService(){
  echo '
[Unit]
Description=Snell Service
After=network.target

[Service]
LimitNOFILE=32767
Type=simple
User=root
Restart=on-failure
RestartSec=5s
ExecStart=/usr/local/bin/snell-server -c /etc/snell/config.conf

[Install]
WantedBy=multi-user.target' > /etc/systemd/system/snell-server.service

  systemctl daemon-reload
  systemctl enable snell-server >/dev/null 2>&1
  echo -e "${Info} Snell Server 服务配置完成！"
}

#========================
# 配置读写
#========================
writeConfig(){
  if [[ -f "${snell_conf}" ]]; then
    cp "${snell_conf}" "${snell_conf}.bak.$(date +%Y%m%d_%H%M%S)"
    echo -e "${Info} 已备份旧配置文件到 ${snell_conf}.bak.*"
  fi
  cat > "${snell_conf}" << EOF
[snell-server]
listen = ::0:${port}
ipv6 = ${ipv6}
psk = ${psk}
obfs = ${obfs}
$(if [[ ${obfs} != "off" ]]; then echo "obfs-host = ${host}"; fi)
tfo = ${tfo}
dns = ${dns}
version = ${ver}
EOF
}

readConfig(){
  [[ ! -e ${snell_conf} ]] && echo -e "${Error} Snell Server 配置文件不存在！" && exit 1
  ipv6=$(grep -E 'ipv6\s*=' ${snell_conf} | awk -F 'ipv6 = ' '{print $NF}' | xargs)
  port=$(grep -E '^listen\s*=' ${snell_conf} | awk -F ':' '{print $NF}' | xargs)
  psk=$(grep -E 'psk\s*=' ${snell_conf} | awk -F 'psk = ' '{print $NF}' | xargs)
  obfs=$(grep -E 'obfs\s*=' ${snell_conf} | awk -F 'obfs = ' '{print $NF}' | xargs)
  host=$(grep -E 'obfs-host\s*=' ${snell_conf} | awk -F 'obfs-host = ' '{print $NF}' | xargs)
  tfo=$(grep -E 'tfo\s*=' ${snell_conf} | awk -F 'tfo = ' '{print $NF}' | xargs)
  dns=$(grep -E 'dns\s*=' ${snell_conf} | awk -F 'dns = ' '{print $NF}' | xargs)
  ver=$(grep -E 'version\s*=' ${snell_conf} | awk -F 'version = ' '{print $NF}' | xargs)
}

#========================
# 交互设置项
#========================
setPort(){
  while true; do
    echo -e "${Tip} 本步骤不涉及系统防火墙端口操作，请手动放行相应端口！"
    echo -e "请输入 Snell Server 端口${Yellow_font_prefix}[1-65535]${Font_color_suffix}"
    read -e -p "(默认: 2345):" port
    [[ -z "${port}" ]] && port="2345"
    if [[ $port =~ ^[0-9]+$ ]] && [[ $port -ge 1 && $port -le 65535 ]]; then
      if ss -tuln | grep -q ":$port "; then
        echo -e "${Error} 端口 $port 已被占用，请选择其他端口。"
      else
        echo && echo "=============================="
        echo -e "端口 : ${Red_background_prefix} ${port} ${Font_color_suffix}"
        echo "==============================" && echo
        break
      fi
    else
      echo -e "${Error} 输入错误, 请输入正确的端口号。"
      sleep 1
    fi
  done
}

setIpv6(){
  echo -e "是否开启 IPv6 解析？
==================================
${Green_font_prefix} 1.${Font_color_suffix} 开启  ${Green_font_prefix} 2.${Font_color_suffix} 关闭
=================================="
  read -e -p "(默认：2.关闭)：" ipv6
  [[ -z "${ipv6}" ]] && ipv6="false"
  if [[ ${ipv6} == "1" ]]; then
    ipv6=true
  else
    ipv6=false
  fi
  echo && echo "=================================="
  echo -e "IPv6 解析 开启状态：${Red_background_prefix} ${ipv6} ${Font_color_suffix}"
  echo "==================================" && echo
}

setPSK(){
  echo "请输入 Snell Server 密钥 [0-9][a-z][A-Z]"
  read -e -p "(默认: 随机生成):" psk
  [[ -z "${psk}" ]] && psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
  echo && echo "=============================="
  echo -e "密钥 : ${Red_background_prefix} ${psk} ${Font_color_suffix}"
  echo "==============================" && echo
}

setHost(){
  echo "请输入 Snell Server 域名，v4 版本及以上如无特别需求可忽略。"
  read -e -p "(默认: icloud.com):" host
  [[ -z "${host}" ]] && host=icloud.com
  echo && echo "=============================="
  echo -e "域名 : ${Red_background_prefix} ${host} ${Font_color_suffix}"
  echo "==============================" && echo
}

setObfs(){
  echo -e "配置 OBFS，${Tip} 无特殊作用不建议启用该项。
==================================
${Green_font_prefix} 1.${Font_color_suffix} TLS  ${Green_font_prefix} 2.${Font_color_suffix} HTTP ${Green_font_prefix} 3.${Font_color_suffix} 关闭
=================================="
  read -e -p "(默认：3.关闭)：" obfs
  [[ -z "${obfs}" ]] && obfs="3"
  if [[ ${obfs} == "1" ]]; then
    obfs="tls"
    setHost
  elif [[ ${obfs} == "2" ]]; then
    obfs="http"
    setHost
  else
    obfs="off"
    host=""
  fi
  echo && echo "=================================="
  echo -e "OBFS 状态：${Red_background_prefix} ${obfs} ${Font_color_suffix}"
  if [[ ${obfs} != "off" ]]; then
    echo -e "OBFS 域名：${Red_background_prefix} ${host} ${Font_color_suffix}"
  fi
  echo "==================================" && echo
}

setTFO(){
  echo -e "是否开启 TCP Fast Open？
==================================
${Green_font_prefix} 1.${Font_color_suffix} 开启  ${Green_font_prefix} 2.${Font_color_suffix} 关闭
=================================="
  read -e -p "(默认：1.开启)：" tfo
  [[ -z "${tfo}" ]] && tfo="1"
  if [[ ${tfo} == "1" ]]; then
    tfo=true
    enableTCPFastOpen
  else
    tfo=false
  fi
  echo && echo "=================================="
  echo -e "TCP Fast Open 开启状态：${Red_background_prefix} ${tfo} ${Font_color_suffix}"
  echo "==================================" && echo
}

setDNS(){
  echo -e "${Tip} 请输入正确格式的 DNS，多条记录以英文逗号隔开。"
  read -e -p "(默认值：1.1.1.1, 8.8.8.8, 2001:4860:4860::8888)：" dns
  [[ -z "${dns}" ]] && dns="1.1.1.1, 8.8.8.8, 2001:4860:4860::8888"
  echo && echo "=================================="
  echo -e "当前 DNS 为：${Red_background_prefix} ${dns} ${Font_color_suffix}"
  echo "==================================" && echo
}

# 更干净的协议版本菜单（仅 v4/v5）
setVer(){
  [[ -z "${ver}" ]] && ver="4"

  echo -e "切换 Snell 协议版本（当前：${Red_background_prefix} v${ver} ${Font_color_suffix}）
=================================="
  if [[ "${ver}" == "5" ]]; then
    echo -e "${Green_font_prefix} 1.${Font_color_suffix} 保持 v5（不变）"
    echo -e "${Green_font_prefix} 2.${Font_color_suffix} 切换到 v4"
    default_choice="1"
  else
    echo -e "${Green_font_prefix} 1.${Font_color_suffix} 保持 v4（不变）"
    echo -e "${Green_font_prefix} 2.${Font_color_suffix} 切换到 v5"
    default_choice="1"
  fi
  echo -e "=================================="
  read -e -p "(默认：${default_choice})：" choice
  [[ -z "${choice}" ]] && choice="${default_choice}"

  if [[ "${choice}" == "4" || "${choice}" == "5" ]]; then
    new_ver="${choice}"
  else
    if [[ "${choice}" == "2" ]]; then
      if [[ "${ver}" == "5" ]]; then
        new_ver="4"
      else
        new_ver="5"
      fi
    else
      new_ver="${ver}"
    fi
  fi

  if [[ "${new_ver}" == "${ver}" ]]; then
    echo -e "${Info} 协议版本未变更，仍为 v${ver}"
  else
    ver="${new_ver}"
    echo -e "${Info} 协议版本已切换为：${Green_font_prefix}v${ver}${Font_color_suffix}"
    echo -e "${Tip} 切换协议版本后将自动重启 Snell 服务以生效。"
  fi
  echo
}

#========================
# 安装/运行控制
#========================
installSnell() {
  checkRoot
  checkSys
  sysArch

  if [[ ! -e "${snell_dir}" ]]; then
    mkdir -p "${snell_dir}"
  else
    [[ -e "${snell_bin}" ]] && rm -rf "${snell_bin}"
  fi

  echo -e "选择安装版本${Yellow_font_prefix}[1-2]${Font_color_suffix}
==================================
${Green_font_prefix} 1.${Font_color_suffix} v5  ${Green_font_prefix} 2.${Font_color_suffix} v4
=================================="
  read -e -p "(默认：1.v5)：" choose_ver
  [[ -z "${choose_ver}" ]] && choose_ver="1"

  echo -e "${Info} 开始设置 配置..."
  setPort
  setPSK
  setObfs
  setIpv6
  setTFO
  setDNS

  # 安装版本同步协议版本（避免二次选择冲突）
  if [[ "${choose_ver}" == "1" ]]; then
    ver=5
  else
    ver=4
  fi
  echo -e "${Info} 当前选择安装：v${ver}（协议版本同步为 v${ver}）"

  echo -e "${Info} 开始安装/配置 依赖..."
  checkDependencies
  installDependencies

  echo -e "${Info} 开始下载/安装..."
  if [[ "${ver}" == "5" ]]; then
    downloadSnellV5 || exit 1
  else
    downloadSnellV4 || exit 1
  fi

  echo -e "${Info} 开始安装 服务脚本..."
  setupService
  echo -e "${Info} 开始写入 配置文件..."
  writeConfig
  echo -e "${Info} 所有步骤 安装完毕，开始启动..."
  startSnell
  echo -e "${Info} 启动完成，查看配置..."
  viewConfig
}

startSnell(){
  checkInstalledStatus
  checkStatus
  if [[ "$status" == "running" ]]; then
    echo -e "${Info} Snell Server 已在运行！"
  else
    echo -e "${Info} 正在启动 Snell Server..."
    systemctl start snell-server

    local timeout=5
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
      sleep 1
      checkStatus
      if [[ "$status" == "running" ]]; then
        echo -e "${Info} Snell Server 启动成功！"
        return 0
      fi
      ((elapsed++))
    done

    checkStatus
    if [[ "$status" == "running" ]]; then
      echo -e "${Info} Snell Server 启动成功！"
    else
      echo -e "${Error} Snell Server 启动失败！"
      echo -e "${Error} 请使用 'systemctl status snell-server' 查看详细错误信息"
      journalctl -u snell-server -n 20 --no-pager
      exit 1
    fi
  fi
}

stopSnell(){
  checkInstalledStatus
  checkStatus
  [[ !"$status" == "running" ]] && echo -e "${Error} Snell Server 没有运行，请检查！" && exit 1
  systemctl stop snell-server
  echo -e "${Info} Snell Server 停止成功！"
  sleep 1
  startMenu
}

restartSnell(){
  checkInstalledStatus
  systemctl restart snell-server
  echo -e "${Info} Snell Server 重启完毕!"
  sleep 1
  startMenu
}

#========================
# 配置菜单
#========================
setConfig(){
  checkInstalledStatus
  echo && echo -e "请输入要操作配置项的序号，然后回车
==============================
 ${Green_font_prefix}1.${Font_color_suffix} 修改 端口
 ${Green_font_prefix}2.${Font_color_suffix} 修改 密钥
 ${Green_font_prefix}3.${Font_color_suffix} 配置 OBFS
 ${Green_font_prefix}4.${Font_color_suffix} 配置 OBFS 域名
 ${Green_font_prefix}5.${Font_color_suffix} 开关 IPv6 解析
 ${Green_font_prefix}6.${Font_color_suffix} 开关 TCP Fast Open
 ${Green_font_prefix}7.${Font_color_suffix} 配置 DNS
 ${Green_font_prefix}8.${Font_color_suffix} 切换 协议版本(v4/v5)（会重启）
==============================
 ${Green_font_prefix}9.${Font_color_suffix} 修改 全部配置" && echo
  read -e -p "(默认: 取消):" modify
  [[ -z "${modify}" ]] && echo "已取消..." && startMenu && return 0

  readConfig
  case "$modify" in
    1) setPort ;;
    2) setPSK ;;
    3) setObfs ;;
    4)
      if [[ ${obfs} == "off" ]]; then
        echo -e "${Error} OBFS 当前为 off，无法修改 OBFS 域名。"
        sleep 1
        startMenu
        return 0
      else
        setHost
      fi
      ;;
    5) setIpv6 ;;
    6) setTFO ;;
    7) setDNS ;;
    8) setVer ;;
    9) setPort; setPSK; setObfs; setIpv6; setTFO; setDNS; setVer ;;
    *) echo -e "${Error} 请输入正确数字[1-9]"; sleep 1; startMenu; return 0 ;;
  esac

  writeConfig
  restartSnell
}

#========================
# 信息查看
#========================
getIpv4(){
  ipv4=$(wget -qO- -4 -t1 -T2 ipinfo.io/ip)
  if [[ -z "${ipv4}" ]]; then
    ipv4=$(wget -qO- -4 -t1 -T2 api.ip.sb/ip)
    if [[ -z "${ipv4}" ]]; then
      ipv4=$(wget -qO- -4 -t1 -T2 members.3322.org/dyndns/getip)
      [[ -z "${ipv4}" ]] && ipv4="IPv4_Error"
    fi
  fi
}

getIpv6(){
  ip6=$(wget -qO- -6 -t1 -T2 ifconfig.co)
  [[ -z "${ip6}" ]] && ip6="IPv6_Error"
}

viewConfig(){
  checkInstalledStatus
  readConfig
  getIpv4
  getIpv6
  clear && echo
  echo -e "Snell Server 配置信息："
  echo -e "—————————————————————————"
  [[ "${ipv4}" != "IPv4_Error" ]] && echo -e " IPv4 地址\t: ${Green_font_prefix}${ipv4}${Font_color_suffix}"
  [[ "${ip6}" != "IPv6_Error" ]] && echo -e " IPv6 地址\t: ${Green_font_prefix}${ip6}${Font_color_suffix}"
  echo -e " 端口\t\t: ${Green_font_prefix}${port}${Font_color_suffix}"
  echo -e " 密钥\t\t: ${Green_font_prefix}${psk}${Font_color_suffix}"
  echo -e " OBFS\t\t: ${Green_font_prefix}${obfs}${Font_color_suffix}"
  echo -e " 域名\t\t: ${Green_font_prefix}${host}${Font_color_suffix}"
  echo -e " IPv6\t\t: ${Green_font_prefix}${ipv6}${Font_color_suffix}"
  echo -e " TFO\t\t: ${Green_font_prefix}${tfo}${Font_color_suffix}"
  echo -e " DNS\t\t: ${Green_font_prefix}${dns}${Font_color_suffix}"
  echo -e " 版本\t\t: ${Green_font_prefix}${ver}${Font_color_suffix}"
  echo -e "—————————————————————————"
  echo -e "${Info} Surge 配置："
  if [[ "${ipv4}" != "IPv4_Error" ]]; then
    if [[ "${obfs}" == "off" ]]; then
      echo -e "$(uname -n) = snell, ${ipv4}, ${port}, psk=${psk}, version=${ver}, tfo=${tfo}, reuse=true, ecn=true"
    else
      echo -e "$(uname -n) = snell, ${ipv4}, ${port}, psk=${psk}, version=${ver}, tfo=${tfo}, obfs=${obfs}, obfs-host=${host}, reuse=true, ecn=true"
    fi
  elif [[ "${ip6}" != "IPv6_Error" ]]; then
    if [[ "${obfs}" == "off" ]]; then
      echo -e "$(uname -n) = snell, [${ip6}], ${port}, psk=${psk}, version=${ver}, tfo=${tfo}, reuse=true, ecn=true"
    else
      echo -e "$(uname -n) = snell, [${ip6}], ${port}, psk=${psk}, version=${ver}, tfo=${tfo}, obfs=${obfs}, obfs-host=${host}, reuse=true, ecn=true"
    fi
  else
    echo -e "${Error} 无法获取 IP 地址！"
  fi
  echo -e "—————————————————————————"
  beforeStartMenu
}

viewStatus(){
  echo -e "${Info} 获取 Snell Server 活动日志 ……"
  echo -e "${Tip} 返回主菜单请按 q ！"
  systemctl status snell-server
  startMenu
}

#========================
# 卸载
#========================
uninstallSnell(){
  checkInstalledStatus
  echo "确定要卸载 Snell Server ? (y/N)"
  read -e -p "(默认: n):" unyn
  [[ -z ${unyn} ]] && unyn="n"
  if [[ ${unyn} == [Yy] ]]; then
    echo -e "${Info} 停止并禁用服务..."
    systemctl stop snell-server >/dev/null 2>&1
    systemctl disable snell-server >/dev/null 2>&1

    echo -e "${Info} 移除主程序..."
    rm -rf "${snell_bin}"

    echo -e "${Info} 移除 systemd 服务文件..."
    rm -f /etc/systemd/system/snell-server.service
    systemctl daemon-reload >/dev/null 2>&1

    echo -e "${Info} 移除网络优化配置..."
    rm -f "${sysctl_conf}"

    echo -e "${Info} 配置文件保留在 ${snell_conf}，如需完全删除请手动执行: rm -rf /etc/snell"
    echo && echo "Snell Server 卸载完成！" && echo
  else
    echo && echo "卸载已取消..." && echo
  fi
  sleep 1
  startMenu
}

#========================
# 菜单
#========================
beforeStartMenu() {
  echo && echo -n -e "${Yellow_font_prefix}* 按回车返回主菜单 *${Font_color_suffix}" && read temp
  startMenu
}

startMenu(){
  clear
  checkRoot
  checkSys
  sysArch

  echo && echo -e "
==============================
Snell Server 管理脚本 ${Red_font_prefix}[${sh_ver}]${Font_color_suffix}
（精简版：仅官方源 dl.nssurge.com）
==============================
 ${Green_font_prefix} 1.${Font_color_suffix} 安装 Snell Server (v4/v5)
 ${Green_font_prefix} 2.${Font_color_suffix} 卸载 Snell Server
——————————————————————————————
 ${Green_font_prefix} 3.${Font_color_suffix} 启动 Snell Server
 ${Green_font_prefix} 4.${Font_color_suffix} 停止 Snell Server
 ${Green_font_prefix} 5.${Font_color_suffix} 重启 Snell Server
——————————————————————————————
 ${Green_font_prefix} 6.${Font_color_suffix} 设置 配置信息
 ${Green_font_prefix} 7.${Font_color_suffix} 查看 配置信息
 ${Green_font_prefix} 8.${Font_color_suffix} 查看 运行状态
——————————————————————————————
 ${Green_font_prefix} 0.${Font_color_suffix} 退出脚本
=============================="
  if [[ -e ${snell_bin} ]]; then
    checkStatus
    if [[ "$status" == "running" ]]; then
      echo -e " 当前状态: ${Green_font_prefix}已安装${Yellow_font_prefix}[v$(grep 'version = ' ${snell_conf} | awk -F 'version = ' '{print $NF}' | xargs)]${Font_color_suffix}并${Green_font_prefix}已启动${Font_color_suffix}"
    else
      echo -e " 当前状态: ${Green_font_prefix}已安装${Yellow_font_prefix}[v$(grep 'version = ' ${snell_conf} | awk -F 'version = ' '{print $NF}' | xargs)]${Font_color_suffix}但${Red_font_prefix}未启动${Font_color_suffix}"
    fi
  else
    echo -e " 当前状态: ${Red_font_prefix}未安装${Font_color_suffix}"
  fi
  echo

  read -e -p " 请输入数字[0-8]:" num
  case "$num" in
    1) installSnell ;;
    2) uninstallSnell ;;
    3) startSnell ;;
    4) stopSnell ;;
    5) restartSnell ;;
    6) setConfig ;;
    7) viewConfig ;;
    8) viewStatus ;;
    0) exit 0 ;;
    *) echo -e "${Error} 请输入正确数字[0-8]"; sleep 1; startMenu ;;
  esac
}

startMenu
