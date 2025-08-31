#!/bin/bash
# GOST管理脚本 - 修复转发和到期时间问题
# 使用正确的rawconf格式

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
PLAIN="\033[0m"

# 版本信息
SCRIPT_VERSION="3.4"
GOST_VERSION="2.11.5"

# 配置路径
CONFIG_DIR="/etc/gost"
GOST_CONFIG="${CONFIG_DIR}/config.json"
RAW_CONFIG="${CONFIG_DIR}/rawconf"
REMARKS_FILE="${CONFIG_DIR}/remarks.txt"
EXPIRES_FILE="${CONFIG_DIR}/expires.txt"

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
        yum install -y wget curl bc iptables >/dev/null 2>&1
    else
        apt-get update >/dev/null 2>&1
        apt-get install -y wget curl bc iptables >/dev/null 2>&1
    fi
}

# 安装GOST
install_gost() {
    echo -e "${GREEN}开始安装GOST ${GOST_VERSION}...${PLAIN}"
    
    systemctl stop gost >/dev/null 2>&1
    
    cd /tmp
    DOWNLOAD_URL="https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/gost-linux-${ARCH}-${GOST_VERSION}.gz"
    
    echo -e "${GREEN}下载GOST...${PLAIN}"
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
    
    mkdir -p ${CONFIG_DIR}
    
    if [[ ! -f ${GOST_CONFIG} ]]; then
        echo '{"Debug":false,"Retries":0,"ServeNodes":[]}' > ${GOST_CONFIG}
    fi
    
    touch ${RAW_CONFIG} ${REMARKS_FILE} ${EXPIRES_FILE}
    
    cat > /etc/systemd/system/gost.service <<EOF
[Unit]
Description=GOST
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/gost -C ${GOST_CONFIG}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gost >/dev/null 2>&1
    systemctl start gost
    
    create_expire_check
    
    echo -e "${GREEN}GOST安装完成${PLAIN}"
}

# 创建过期检查
create_expire_check() {
    cat > /usr/local/bin/gost-expire-check <<'EOF'
#!/bin/bash
CONFIG_DIR="/etc/gost"
RAW_CONFIG="${CONFIG_DIR}/rawconf"
EXPIRES_FILE="${CONFIG_DIR}/expires.txt"

if [[ ! -f ${EXPIRES_FILE} ]]; then
    exit 0
fi

current_time=$(date +%s)
temp_file="/tmp/expires_temp"
need_rebuild=false

> ${temp_file}

while IFS=: read -r port expire_time; do
    if [[ "${expire_time}" != "permanent" ]] && [[ ${expire_time} -lt ${current_time} ]]; then
        # 删除过期规则 - 修正格式
        sed -i "/^nonencrypt\/${port}#/d" ${RAW_CONFIG}
        sed -i "/^${port}:/d" ${CONFIG_DIR}/remarks.txt
        need_rebuild=true
        echo "[$(date)] Port ${port} expired and removed" >> /var/log/gost.log
    else
        echo "${port}:${expire_time}" >> ${temp_file}
    fi
done < ${EXPIRES_FILE}

mv -f ${temp_file} ${EXPIRES_FILE}

if [[ ${need_rebuild} == true ]]; then
    /usr/local/bin/gost-manager --rebuild
fi
EOF
    chmod +x /usr/local/bin/gost-expire-check
    
    echo "0 * * * * root /usr/local/bin/gost-expire-check >/dev/null 2>&1" > /etc/cron.d/gost-expire
}

# 修复g命令
fix_g_command() {
    CURRENT_SCRIPT=$(readlink -f "$0")
    
    cp -f "${CURRENT_SCRIPT}" /usr/local/bin/gost-manager
    chmod +x /usr/local/bin/gost-manager
    
    cat > /usr/bin/g <<'EOF'
#!/bin/bash
exec /usr/local/bin/gost-manager "$@"
EOF
    chmod +x /usr/bin/g
    
    echo -e "${GREEN}快捷命令 'g' 修复成功${PLAIN}"
}

# iptables流量统计
init_iptables() {
    if ! command -v iptables >/dev/null 2>&1; then
        ${PACKAGE_MANAGER} install -y iptables iptables-services >/dev/null 2>&1
    fi
    
    iptables -t filter -F GOST 2>/dev/null
    iptables -t filter -X GOST 2>/dev/null
    
    iptables -t filter -N GOST 2>/dev/null
    iptables -t filter -C INPUT -j GOST 2>/dev/null || iptables -t filter -A INPUT -j GOST
    iptables -t filter -C OUTPUT -j GOST 2>/dev/null || iptables -t filter -A OUTPUT -j GOST
}

# 添加端口流量规则
add_traffic_rule() {
    local port=$1
    
    iptables -t filter -C GOST -p tcp --dport ${port} -j ACCEPT 2>/dev/null || \
        iptables -t filter -A GOST -p tcp --dport ${port} -j ACCEPT
    iptables -t filter -C GOST -p udp --dport ${port} -j ACCEPT 2>/dev/null || \
        iptables -t filter -A GOST -p udp --dport ${port} -j ACCEPT
    iptables -t filter -C GOST -p tcp --sport ${port} -j ACCEPT 2>/dev/null || \
        iptables -t filter -A GOST -p tcp --sport ${port} -j ACCEPT
    iptables -t filter -C GOST -p udp --sport ${port} -j ACCEPT 2>/dev/null || \
        iptables -t filter -A GOST -p udp --sport ${port} -j ACCEPT
}

# 删除端口流量规则
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
    
    local in_tcp=$(iptables -t filter -nvxL GOST 2>/dev/null | grep "dpt:${port}" | grep tcp | awk '{s=sprintf("%.0f",$2); sum+=s}END{print sum+0}')
    local in_udp=$(iptables -t filter -nvxL GOST 2>/dev/null | grep "dpt:${port}" | grep udp | awk '{s=sprintf("%.0f",$2); sum+=s}END{print sum+0}')
    local out_tcp=$(iptables -t filter -nvxL GOST 2>/dev/null | grep "spt:${port}" | grep tcp | awk '{s=sprintf("%.0f",$2); sum+=s}END{print sum+0}')
    local out_udp=$(iptables -t filter -nvxL GOST 2>/dev/null | grep "spt:${port}" | grep udp | awk '{s=sprintf("%.0f",$2); sum+=s}END{print sum+0}')
    
    local in_bytes=$((in_tcp + in_udp))
    local out_bytes=$((out_tcp + out_udp))
    
    echo "${in_bytes}:${out_bytes}"
}

# 格式化字节
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

# 格式化到期时间
format_expire_time() {
    local expire_time=$1
    
    if [[ "${expire_time}" == "permanent" ]]; then
        echo "永久"
        return
    fi
    
    local current_time=$(date +%s)
    local diff=$((expire_time - current_time))
    
    if [[ ${diff} -le 0 ]]; then
        echo "已过期"
    elif [[ ${diff} -lt 3600 ]]; then
        echo "$((diff / 60))分钟"
    elif [[ ${diff} -lt 86400 ]]; then
        echo "$((diff / 3600))小时"
    else
        echo "$((diff / 86400))天"
    fi
}

# 重建配置 - 使用正确的格式
rebuild_config() {
    if [[ ! -s ${RAW_CONFIG} ]]; then
        echo '{"Debug":false,"Retries":0,"ServeNodes":[]}' > ${GOST_CONFIG}
    else
        {
            echo '{"Debug":false,"Retries":0,"ServeNodes":['
            local first=true
            while IFS= read -r line; do
                # 解析格式: nonencrypt/端口#目标IP#目标端口
                if [[ ${line} =~ ^nonencrypt/([0-9]+)#(.+)#([0-9]+)$ ]]; then
                    local port="${BASH_REMATCH[1]}"
                    local target="${BASH_REMATCH[2]}"
                    local target_port="${BASH_REMATCH[3]}"
                    
                    if [[ ${first} == false ]]; then
                        echo ","
                    fi
                    first=false
                    
                    echo -n "        \"tcp://:${port}/${target}:${target_port}\","
                    echo -n "\"udp://:${port}/${target}:${target_port}\""
                fi
            done < ${RAW_CONFIG}
            echo ""
            echo "    ]"
            echo "}"
        } > ${GOST_CONFIG}
    fi
    
    systemctl restart gost >/dev/null 2>&1
}

# 检查过期
check_expired() {
    [[ ! -f ${EXPIRES_FILE} ]] && return
    
    local current_time=$(date +%s)
    local temp_file="/tmp/expires_temp_$$"
    local need_rebuild=false
    
    > ${temp_file}
    
    while IFS=: read -r port expire_time; do
        if [[ "${expire_time}" != "permanent" ]] && [[ ${expire_time} -lt ${current_time} ]]; then
            sed -i "/^nonencrypt\/${port}#/d" ${RAW_CONFIG}
            sed -i "/^${port}:/d" ${REMARKS_FILE}
            del_traffic_rule ${port}
            need_rebuild=true
            echo -e "${YELLOW}端口 ${port} 已过期删除${PLAIN}"
        else
            echo "${port}:${expire_time}" >> ${temp_file}
        fi
    done < ${EXPIRES_FILE}
    
    mv -f ${temp_file} ${EXPIRES_FILE}
    
    [[ ${need_rebuild} == true ]] && rebuild_config
}

# 显示头部
show_header() {
    clear
    echo -e "${BLUE}================================================${PLAIN}"
    echo -e "${GREEN}       GOST 端口转发管理面板 v${SCRIPT_VERSION}${PLAIN}"
    echo -e "${BLUE}================================================${PLAIN}"
    
    local gost_status=$(systemctl is-active gost 2>/dev/null || echo "未运行")
    local gost_version=$(gost -V 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "未安装")
    local rule_count=$(wc -l < ${RAW_CONFIG} 2>/dev/null || echo "0")
    
    echo -e "状态: ${GREEN}${gost_status}${PLAIN} | 版本: ${GREEN}${gost_version}${PLAIN} | 规则: ${GREEN}${rule_count}${PLAIN}"
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
    echo -e "${BLUE}--------------------------------------------------------------------------------${PLAIN}"
    printf "%-4s %-10s %-25s %-12s %-10s %-15s\n" "ID" "端口" "目标" "备注" "到期" "流量"
    echo -e "${BLUE}--------------------------------------------------------------------------------${PLAIN}"
    
    local id=1
    while IFS= read -r line; do
        # 解析格式: nonencrypt/端口#目标IP#目标端口
        if [[ ${line} =~ ^nonencrypt/([0-9]+)#(.+)#([0-9]+)$ ]]; then
            local port="${BASH_REMATCH[1]}"
            local target="${BASH_REMATCH[2]}"
            local target_port="${BASH_REMATCH[3]}"
            
            local remark=$(grep "^${port}:" ${REMARKS_FILE} 2>/dev/null | cut -d':' -f2- || echo "-")
            [[ ${#remark} -gt 10 ]] && remark="${remark:0:10}.."
            
            local expire_time=$(grep "^${port}:" ${EXPIRES_FILE} 2>/dev/null | cut -d':' -f2 || echo "permanent")
            local expire_display=$(format_expire_time "${expire_time}")
            
            local traffic_data=$(get_port_traffic ${port})
            local in_bytes=$(echo "${traffic_data}" | cut -d':' -f1)
            local out_bytes=$(echo "${traffic_data}" | cut -d':' -f2)
            local total_bytes=$((in_bytes + out_bytes))
            local traffic_display=$(format_bytes ${total_bytes})
            
            if [[ "${expire_display}" == "已过期" ]]; then
                expire_color="${RED}"
            elif [[ "${expire_display}" == *"分钟"* ]] || [[ "${expire_display}" == *"小时"* ]]; then
                expire_color="${YELLOW}"
            else
                expire_color=""
            fi
            
            printf "%-4s %-10s %-25s %-12s ${expire_color}%-10s${PLAIN} %-15s\n" \
                "${id}" "${port}" "${target}:${target_port}" "${remark}" "${expire_display}" "${traffic_display}"
            
            ((id++))
        fi
    done < ${RAW_CONFIG}
}

# 添加转发
add_forward() {
    echo -e "${GREEN}添加转发规则${PLAIN}"
    
    read -p "本地端口: " local_port
    read -p "目标地址: " target_ip
    read -p "目标端口: " target_port
    read -p "备注(可选): " remark
    
    if [[ ! ${local_port} =~ ^[0-9]+$ ]] || [[ ! ${target_port} =~ ^[0-9]+$ ]]; then
        echo -e "${RED}端口必须为数字${PLAIN}"
        return
    fi
    
    if grep -q "^nonencrypt/${local_port}#" ${RAW_CONFIG} 2>/dev/null; then
        echo -e "${RED}端口 ${local_port} 已被使用${PLAIN}"
        return
    fi
    
    echo -e "${GREEN}设置到期时间:${PLAIN}"
    echo "1) 永久"
    echo "2) 1天"
    echo "3) 7天"
    echo "4) 30天"
    echo "5) 自定义(天)"
    read -p "选择 [1-5]: " expire_choice
    
    local expire_time="permanent"
    case ${expire_choice} in
        2)
            expire_time=$(($(date +%s) + 86400))
            echo -e "${GREEN}到期时间: 1天${PLAIN}"
            ;;
        3)
            expire_time=$(($(date +%s) + 604800))
            echo -e "${GREEN}到期时间: 7天${PLAIN}"
            ;;
        4)
            expire_time=$(($(date +%s) + 2592000))
            echo -e "${GREEN}到期时间: 30天${PLAIN}"
            ;;
        5)
            read -p "输入天数: " days
            if [[ ${days} =~ ^[0-9]+$ ]] && [[ ${days} -gt 0 ]]; then
                expire_time=$(($(date +%s) + days * 86400))
                echo -e "${GREEN}到期时间: ${days}天${PLAIN}"
            else
                expire_time="permanent"
                echo -e "${GREEN}设置为永久${PLAIN}"
            fi
            ;;
        *)
            expire_time="permanent"
            echo -e "${GREEN}设置为永久${PLAIN}"
            ;;
    esac
    
    # 使用正确的格式
    echo "nonencrypt/${local_port}#${target_ip}#${target_port}" >> ${RAW_CONFIG}
    
    [[ -n ${remark} ]] && echo "${local_port}:${remark}" >> ${REMARKS_FILE}
    echo "${local_port}:${expire_time}" >> ${EXPIRES_FILE}
    
    add_traffic_rule ${local_port}
    rebuild_config
    
    echo -e "${GREEN}添加成功: ${local_port} -> ${target_ip}:${target_port}${PLAIN}"
}

# 删除转发
del_forward() {
    show_forwards
    echo
    read -p "输入要删除的ID: " rule_id
    
    if [[ ! ${rule_id} =~ ^[0-9]+$ ]]; then
        echo -e "${RED}无效ID${PLAIN}"
        return
    fi
    
    local line=$(sed -n "${rule_id}p" ${RAW_CONFIG} 2>/dev/null)
    if [[ -z ${line} ]]; then
        echo -e "${RED}规则不存在${PLAIN}"
        return
    fi
    
    if [[ ${line} =~ ^nonencrypt/([0-9]+)# ]]; then
        local port="${BASH_REMATCH[1]}"
        
        sed -i "${rule_id}d" ${RAW_CONFIG}
        sed -i "/^${port}:/d" ${REMARKS_FILE}
        sed -i "/^${port}:/d" ${EXPIRES_FILE}
        
        del_traffic_rule ${port}
        rebuild_config
        
        echo -e "${GREEN}删除成功${PLAIN}"
    fi
}

# 查看流量
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
        if [[ ${line} =~ ^nonencrypt/([0-9]+)# ]]; then
            local port="${BASH_REMATCH[1]}"
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
        fi
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
        echo -e "${GREEN}1.${PLAIN} 添加转发"
        echo -e "${GREEN}2.${PLAIN} 删除转发"
        echo -e "${GREEN}3.${PLAIN} 查看流量"
        echo -e "${GREEN}4.${PLAIN} 重启服务"
        echo -e "${GREEN}5.${PLAIN} 查看日志"
        echo -e "${GREEN}6.${PLAIN} 修复g命令"
        echo -e "${GREEN}0.${PLAIN} 退出"
        echo
        
        read -p "选择 [0-6]: " choice
        
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
                echo -e "${GREEN}GOST日志:${PLAIN}"
                journalctl -u gost -n 30 --no-pager
                read -p "按Enter继续..."
                ;;
            6)
                fix_g_command
                echo -e "${GREEN}请重新输入 g${PLAIN}"
                exit 0
                ;;
            0)
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择${PLAIN}"
                sleep 1
                ;;
        esac
    done
}

# 主函数
main() {
    check_root
    check_system
    
    if [[ "$1" == "--rebuild" ]]; then
        rebuild_config
        exit 0
    fi
    
    if [[ ! -f /usr/bin/gost ]]; then
        echo -e "${YELLOW}GOST未安装，开始安装...${PLAIN}"
        install_deps
        install_gost
        init_iptables
    fi
    
    fix_g_command
    init_iptables
    
    if [[ -s ${RAW_CONFIG} ]]; then
        while IFS= read -r line; do
            if [[ ${line} =~ ^nonencrypt/([0-9]+)# ]]; then
                add_traffic_rule "${BASH_REMATCH[1]}"
            fi
        done < ${RAW_CONFIG}
    fi
    
    main_menu
}

main "$@"
