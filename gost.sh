#!/bin/bash
# GOST管理脚本 v3.0 - 完全修复版
# 作者: github.com/xmg0828-01
# 功能: 端口转发管理、流量统计、到期时间管理

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
PLAIN="\033[0m"

# 版本信息
SCRIPT_VERSION="3.0"
GOST_VERSION="2.11.5"

# 配置路径
CONFIG_DIR="/etc/gost"
GOST_CONFIG="${CONFIG_DIR}/config.json"
RAW_CONFIG="${CONFIG_DIR}/rawconf"
REMARKS_FILE="${CONFIG_DIR}/remarks.txt"
EXPIRES_FILE="${CONFIG_DIR}/expires.txt"
TRAFFIC_DB="${CONFIG_DIR}/traffic.db"

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 请使用root权限运行${PLAIN}"
        exit 1
    fi
}

# 检测系统
check_system() {
    if [[ -f /etc/redhat-release ]]; then
        OS="centos"
        PACKAGE_MANAGER="yum"
    elif cat /etc/issue | grep -q -E -i "debian|ubuntu"; then
        OS="debian"
        PACKAGE_MANAGER="apt-get"
    else
        echo -e "${RED}不支持的系统${PLAIN}"
        exit 1
    fi
    
    ARCH=$(uname -m)
    if [[ ${ARCH} == "x86_64" ]]; then
        ARCH="amd64"
    elif [[ ${ARCH} == "aarch64" ]]; then
        ARCH="arm64"
    else
        ARCH="amd64"
    fi
}

# 安装依赖
install_deps() {
    echo -e "${GREEN}安装依赖包...${PLAIN}"
    if [[ ${OS} == "centos" ]]; then
        yum install -y wget curl jq bc iptables >/dev/null 2>&1
    else
        apt-get update >/dev/null 2>&1
        apt-get install -y wget curl jq bc iptables >/dev/null 2>&1
    fi
}

# 下载并安装GOST
install_gost() {
    echo -e "${GREEN}开始安装GOST...${PLAIN}"
    
    # 停止旧服务
    systemctl stop gost >/dev/null 2>&1
    
    # 下载最新版GOST
    cd /tmp
    DOWNLOAD_URL="https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/gost-linux-${ARCH}-${GOST_VERSION}.gz"
    
    echo -e "${GREEN}下载GOST ${GOST_VERSION}...${PLAIN}"
    if ! wget --no-check-certificate -q --show-progress --timeout=30 -O gost.gz "${DOWNLOAD_URL}"; then
        echo -e "${YELLOW}Github下载失败，尝试镜像源...${PLAIN}"
        MIRROR_URL="https://ghproxy.com/${DOWNLOAD_URL}"
        if ! wget --no-check-certificate -q --show-progress --timeout=30 -O gost.gz "${MIRROR_URL}"; then
            echo -e "${RED}下载失败${PLAIN}"
            exit 1
        fi
    fi
    
    gunzip -f gost.gz
    chmod +x gost
    mv -f gost /usr/bin/gost
    
    # 创建配置目录
    mkdir -p ${CONFIG_DIR}
    
    # 初始化配置文件
    if [[ ! -f ${GOST_CONFIG} ]]; then
        echo '{"Debug":false,"Retries":0,"ServeNodes":[]}' > ${GOST_CONFIG}
    fi
    
    touch ${RAW_CONFIG} ${REMARKS_FILE} ${EXPIRES_FILE} ${TRAFFIC_DB}
    
    # 创建systemd服务
    cat > /etc/systemd/system/gost.service <<EOF
[Unit]
Description=GOST Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/gost -C ${GOST_CONFIG}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gost >/dev/null 2>&1
    systemctl start gost
    
    echo -e "${GREEN}GOST安装完成${PLAIN}"
}

# 创建快捷命令
create_shortcut() {
    # 复制脚本到系统目录
    cp -f "$0" /usr/local/bin/gost-manager
    chmod +x /usr/local/bin/gost-manager
    
    # 创建软链接
    ln -sf /usr/local/bin/gost-manager /usr/bin/g
    
    echo -e "${GREEN}快捷命令 'g' 创建成功${PLAIN}"
}

# 初始化iptables规则
init_iptables() {
    # 检查iptables
    if ! command -v iptables >/dev/null 2>&1; then
        echo -e "${YELLOW}安装iptables...${PLAIN}"
        ${PACKAGE_MANAGER} install -y iptables iptables-services >/dev/null 2>&1
    fi
    
    # 清理旧规则
    iptables -t filter -F GOST 2>/dev/null
    iptables -t filter -X GOST 2>/dev/null
    
    # 创建GOST链
    iptables -t filter -N GOST 2>/dev/null
    iptables -t filter -C INPUT -j GOST 2>/dev/null || iptables -t filter -A INPUT -j GOST
    iptables -t filter -C OUTPUT -j GOST 2>/dev/null || iptables -t filter -A OUTPUT -j GOST
}

# 添加端口流量统计规则
add_traffic_rule() {
    local port=$1
    
    # 入站流量统计
    iptables -t filter -C GOST -p tcp --dport ${port} -j ACCEPT 2>/dev/null || \
        iptables -t filter -A GOST -p tcp --dport ${port} -j ACCEPT
    iptables -t filter -C GOST -p udp --dport ${port} -j ACCEPT 2>/dev/null || \
        iptables -t filter -A GOST -p udp --dport ${port} -j ACCEPT
    
    # 出站流量统计
    iptables -t filter -C GOST -p tcp --sport ${port} -j ACCEPT 2>/dev/null || \
        iptables -t filter -A GOST -p tcp --sport ${port} -j ACCEPT
    iptables -t filter -C GOST -p udp --sport ${port} -j ACCEPT 2>/dev/null || \
        iptables -t filter -A GOST -p udp --sport ${port} -j ACCEPT
}

# 删除端口流量统计规则
del_traffic_rule() {
    local port=$1
    
    iptables -t filter -D GOST -p tcp --dport ${port} -j ACCEPT 2>/dev/null
    iptables -t filter -D GOST -p udp --dport ${port} -j ACCEPT 2>/dev/null
    iptables -t filter -D GOST -p tcp --sport ${port} -j ACCEPT 2>/dev/null
    iptables -t filter -D GOST -p udp --sport ${port} -j ACCEPT 2>/dev/null
}

# 获取端口流量
get_port_traffic() {
    local port=$1
    local in_bytes=0
    local out_bytes=0
    
    # 获取入站流量
    local tcp_in=$(iptables -t filter -nvxL GOST 2>/dev/null | grep "dpt:${port}" | grep tcp | awk '{sum+=$2}END{print sum+0}')
    local udp_in=$(iptables -t filter -nvxL GOST 2>/dev/null | grep "dpt:${port}" | grep udp | awk '{sum+=$2}END{print sum+0}')
    in_bytes=$((tcp_in + udp_in))
    
    # 获取出站流量
    local tcp_out=$(iptables -t filter -nvxL GOST 2>/dev/null | grep "spt:${port}" | grep tcp | awk '{sum+=$2}END{print sum+0}')
    local udp_out=$(iptables -t filter -nvxL GOST 2>/dev/null | grep "spt:${port}" | grep udp | awk '{sum+=$2}END{print sum+0}')
    out_bytes=$((tcp_out + udp_out))
    
    echo "${in_bytes}:${out_bytes}"
}

# 格式化字节数
format_bytes() {
    local bytes=$1
    
    if [[ ${bytes} -lt 1024 ]]; then
        echo "${bytes}B"
    elif [[ ${bytes} -lt 1048576 ]]; then
        echo "$(echo "scale=2; ${bytes}/1024" | bc)KB"
    elif [[ ${bytes} -lt 1073741824 ]]; then
        echo "$(echo "scale=2; ${bytes}/1048576" | bc)MB"
    else
        echo "$(echo "scale=2; ${bytes}/1073741824" | bc)GB"
    fi
}

# 重建GOST配置
rebuild_config() {
    if [[ ! -s ${RAW_CONFIG} ]]; then
        echo '{"Debug":false,"Retries":0,"ServeNodes":[]}' > ${GOST_CONFIG}
    else
        echo '{"Debug":false,"Retries":0,"ServeNodes":[' > ${GOST_CONFIG}
        
        local first=true
        while IFS= read -r line; do
            local port=$(echo "${line}" | cut -d'/' -f2 | cut -d'#' -f1)
            local target=$(echo "${line}" | cut -d'#' -f2)
            local target_port=$(echo "${line}" | cut -d'#' -f3)
            
            if [[ ${first} == false ]]; then
                echo "," >> ${GOST_CONFIG}
            fi
            first=false
            
            echo -n "\"tcp://:${port}/${target}:${target_port}\",\"udp://:${port}/${target}:${target_port}\"" >> ${GOST_CONFIG}
        done < ${RAW_CONFIG}
        
        echo "" >> ${GOST_CONFIG}
        echo "]}" >> ${GOST_CONFIG}
    fi
    
    systemctl restart gost >/dev/null 2>&1
}

# 检查过期规则
check_expired() {
    local current_time=$(date +%s)
    local need_rebuild=false
    
    if [[ -f ${EXPIRES_FILE} ]]; then
        while IFS=: read -r port expire_time; do
            if [[ "${expire_time}" != "永久" ]] && [[ ${expire_time} -le ${current_time} ]]; then
                # 删除过期规则
                sed -i "/\/${port}#/d" ${RAW_CONFIG}
                sed -i "/^${port}:/d" ${EXPIRES_FILE}
                sed -i "/^${port}:/d" ${REMARKS_FILE}
                sed -i "/^${port}:/d" ${TRAFFIC_DB}
                del_traffic_rule ${port}
                need_rebuild=true
                echo -e "${YELLOW}端口 ${port} 已过期并删除${PLAIN}"
            fi
        done < ${EXPIRES_FILE}
    fi
    
    if [[ ${need_rebuild} == true ]]; then
        rebuild_config
    fi
}

# 显示菜单头
show_header() {
    clear
    echo -e "${BLUE}================================================${PLAIN}"
    echo -e "${GREEN}       GOST 端口转发管理面板 v${SCRIPT_VERSION}${PLAIN}"
    echo -e "${BLUE}================================================${PLAIN}"
    
    # 显示系统状态
    local gost_status=$(systemctl is-active gost 2>/dev/null || echo "未运行")
    local gost_version=$(gost -V 2>/dev/null | awk '{print $2}' || echo "未安装")
    local rule_count=$(wc -l < ${RAW_CONFIG} 2>/dev/null || echo "0")
    
    echo -e "GOST状态: ${GREEN}${gost_status}${PLAIN} | 版本: ${GREEN}${gost_version}${PLAIN} | 规则数: ${GREEN}${rule_count}${PLAIN}"
    echo -e "${BLUE}================================================${PLAIN}"
    echo
}

# 显示转发列表
show_forwards() {
    if [[ ! -s ${RAW_CONFIG} ]]; then
        echo -e "${YELLOW}暂无转发规则${PLAIN}"
        return
    fi
    
    echo -e "${GREEN}转发规则列表:${PLAIN}"
    echo -e "${BLUE}-----------------------------------------------------------${PLAIN}"
    printf "%-4s %-10s %-25s %-15s %-12s\n" "ID" "端口" "目标" "备注" "流量"
    echo -e "${BLUE}-----------------------------------------------------------${PLAIN}"
    
    local id=1
    while IFS= read -r line; do
        local port=$(echo "${line}" | cut -d'/' -f2 | cut -d'#' -f1)
        local target=$(echo "${line}" | cut -d'#' -f2)
        local target_port=$(echo "${line}" | cut -d'#' -f3)
        
        # 获取备注
        local remark=$(grep "^${port}:" ${REMARKS_FILE} 2>/dev/null | cut -d':' -f2- || echo "-")
        
        # 获取流量
        local traffic_data=$(get_port_traffic ${port})
        local in_bytes=$(echo "${traffic_data}" | cut -d':' -f1)
        local out_bytes=$(echo "${traffic_data}" | cut -d':' -f2)
        local total_bytes=$((in_bytes + out_bytes))
        local traffic_display=$(format_bytes ${total_bytes})
        
        printf "%-4s %-10s %-25s %-15s %-12s\n" \
            "${id}" "${port}" "${target}:${target_port}" "${remark}" "${traffic_display}"
        
        ((id++))
    done < ${RAW_CONFIG}
}

# 添加转发规则
add_forward() {
    echo -e "${GREEN}添加转发规则${PLAIN}"
    
    read -p "本地端口: " local_port
    read -p "目标地址: " target_ip
    read -p "目标端口: " target_port
    read -p "备注信息: " remark
    
    # 验证输入
    if [[ ! ${local_port} =~ ^[0-9]+$ ]] || [[ ! ${target_port} =~ ^[0-9]+$ ]]; then
        echo -e "${RED}端口必须为数字${PLAIN}"
        return
    fi
    
    # 检查端口是否已使用
    if grep -q "/${local_port}#" ${RAW_CONFIG} 2>/dev/null; then
        echo -e "${RED}端口 ${local_port} 已被使用${PLAIN}"
        return
    fi
    
    # 添加规则
    echo "tcp/${local_port}#${target_ip}#${target_port}" >> ${RAW_CONFIG}
    
    # 保存备注
    if [[ -n ${remark} ]]; then
        echo "${local_port}:${remark}" >> ${REMARKS_FILE}
    fi
    
    # 设置永久有效
    echo "${local_port}:永久" >> ${EXPIRES_FILE}
    
    # 添加流量统计
    add_traffic_rule ${local_port}
    
    # 重建配置
    rebuild_config
    
    echo -e "${GREEN}添加成功: ${local_port} -> ${target_ip}:${target_port}${PLAIN}"
}

# 删除转发规则
del_forward() {
    show_forwards
    echo
    read -p "请输入要删除的规则ID: " rule_id
    
    if [[ ! ${rule_id} =~ ^[0-9]+$ ]]; then
        echo -e "${RED}无效的ID${PLAIN}"
        return
    fi
    
    local line=$(sed -n "${rule_id}p" ${RAW_CONFIG} 2>/dev/null)
    if [[ -z ${line} ]]; then
        echo -e "${RED}规则不存在${PLAIN}"
        return
    fi
    
    local port=$(echo "${line}" | cut -d'/' -f2 | cut -d'#' -f1)
    
    # 删除规则
    sed -i "${rule_id}d" ${RAW_CONFIG}
    sed -i "/^${port}:/d" ${REMARKS_FILE}
    sed -i "/^${port}:/d" ${EXPIRES_FILE}
    sed -i "/^${port}:/d" ${TRAFFIC_DB}
    
    # 删除流量统计
    del_traffic_rule ${port}
    
    # 重建配置
    rebuild_config
    
    echo -e "${GREEN}删除成功${PLAIN}"
}

# 查看流量统计
show_traffic() {
    if [[ ! -s ${RAW_CONFIG} ]]; then
        echo -e "${YELLOW}暂无转发规则${PLAIN}"
        return
    fi
    
    echo -e "${GREEN}流量统计:${PLAIN}"
    echo -e "${BLUE}-----------------------------------------------------------${PLAIN}"
    printf "%-10s %-15s %-15s %-15s\n" "端口" "入站" "出站" "总计"
    echo -e "${BLUE}-----------------------------------------------------------${PLAIN}"
    
    local total_in=0
    local total_out=0
    
    while IFS= read -r line; do
        local port=$(echo "${line}" | cut -d'/' -f2 | cut -d'#' -f1)
        local traffic_data=$(get_port_traffic ${port})
        local in_bytes=$(echo "${traffic_data}" | cut -d':' -f1)
        local out_bytes=$(echo "${traffic_data}" | cut -d':' -f2)
        local total_bytes=$((in_bytes + out_bytes))
        
        total_in=$((total_in + in_bytes))
        total_out=$((total_out + out_bytes))
        
        printf "%-10s %-15s %-15s %-15s\n" \
            "${port}" \
            "$(format_bytes ${in_bytes})" \
            "$(format_bytes ${out_bytes})" \
            "$(format_bytes ${total_bytes})"
    done < ${RAW_CONFIG}
    
    echo -e "${BLUE}-----------------------------------------------------------${PLAIN}"
    printf "%-10s %-15s %-15s %-15s\n" \
        "总计" \
        "$(format_bytes ${total_in})" \
        "$(format_bytes ${total_out})" \
        "$(format_bytes $((total_in + total_out)))"
}

# 主菜单
main_menu() {
    while true; do
        show_header
        check_expired
        show_forwards
        echo
        echo -e "${GREEN}操作菜单:${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} 添加转发规则"
        echo -e "${GREEN}2.${PLAIN} 删除转发规则"
        echo -e "${GREEN}3.${PLAIN} 查看流量统计"
        echo -e "${GREEN}4.${PLAIN} 重启GOST服务"
        echo -e "${GREEN}5.${PLAIN} 更新GOST版本"
        echo -e "${GREEN}6.${PLAIN} 卸载GOST"
        echo -e "${GREEN}0.${PLAIN} 退出"
        echo
        
        read -p "请选择 [0-6]: " choice
        
        case ${choice} in
            1)
                add_forward
                read -p "按Enter继续..."
                ;;
            2)
                del_forward
                read -p "按Enter继续..."
                ;;
            3)
                clear
                show_header
                show_traffic
                echo
                read -p "按Enter继续..."
                ;;
            4)
                systemctl restart gost
                echo -e "${GREEN}重启成功${PLAIN}"
                sleep 2
                ;;
            5)
                install_gost
                sleep 2
                ;;
            6)
                read -p "确定要卸载GOST吗？(y/n): " confirm
                if [[ ${confirm} == "y" ]]; then
                    systemctl stop gost
                    systemctl disable gost
                    rm -f /usr/bin/gost /usr/bin/g
                    rm -f /usr/local/bin/gost-manager
                    rm -rf ${CONFIG_DIR}
                    rm -f /etc/systemd/system/gost.service
                    
                    # 清理iptables
                    iptables -t filter -F GOST 2>/dev/null
                    iptables -t filter -X GOST 2>/dev/null
                    
                    echo -e "${GREEN}卸载完成${PLAIN}"
                    exit 0
                fi
                ;;
            0)
                echo -e "${GREEN}再见！${PLAIN}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择${PLAIN}"
                sleep 2
                ;;
        esac
    done
}

# 主函数
main() {
    check_root
    check_system
    
    # 检查是否已安装
    if [[ ! -f /usr/bin/gost ]]; then
        echo -e "${YELLOW}GOST未安装，开始安装...${PLAIN}"
        install_deps
        install_gost
        init_iptables
    fi
    
    # 创建快捷命令
    if [[ ! -f /usr/bin/g ]]; then
        create_shortcut
    fi
    
    # 初始化iptables
    init_iptables
    
    # 为已有规则添加流量统计
    if [[ -s ${RAW_CONFIG} ]]; then
        while IFS= read -r line; do
            local port=$(echo "${line}" | cut -d'/' -f2 | cut -d'#' -f1)
            add_traffic_rule ${port}
        done < ${RAW_CONFIG}
    fi
    
    # 显示主菜单
    main_menu
}

# 运行主函数
main "$@"
