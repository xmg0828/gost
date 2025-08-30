#!/bin/bash
# GOST 增强版管理脚本 v2.4.0 - 流量统计与到期管理
# 一键安装: bash <(curl -sSL https://raw.githubusercontent.com/xmg0828-01/gost/main/gost.sh)
# 快捷使用: g

Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Yellow_font_prefix="\033[33m"
Blue_font_prefix="\033[34m" && Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Warning="${Yellow_font_prefix}[警告]${Font_color_suffix}"
shell_version="2.4.0"
ct_new_ver="2.11.5"

gost_conf_path="/etc/gost/config.json"
raw_conf_path="/etc/gost/rawconf"
remarks_path="/etc/gost/remarks.txt"
expires_path="/etc/gost/expires.txt"
traffic_path="/etc/gost/traffic.db"
traffic_history="/etc/gost/traffic_history.db"

check_root() {
    [[ $EUID != 0 ]] && echo -e "${Error} 请使用root权限运行此脚本" && exit 1
}

detect_environment() {
    if [[ -f /etc/redhat-release ]]; then
        release="centos"
    elif cat /etc/issue | grep -q -E -i "debian|ubuntu"; then
        release="debian" 
    fi
    
    case $(uname -m) in
        x86_64) arch="amd64" ;;
        *) arch="amd64" ;;
    esac
}

is_oneclick_install() {
    [[ "$0" =~ /dev/fd/ ]] || [[ "$0" == "bash" ]] || [[ "$0" =~ /proc/self/fd/ ]]
}

install_gost() {
    echo -e "${Info} 开始安装GOST..."
    detect_environment
    
    # 安装基础工具
    echo -e "${Info} 安装基础工具..."
    if [[ $release == "centos" ]]; then
        yum install -y wget curl bc >/dev/null 2>&1
    else
        apt-get install -y wget curl bc >/dev/null 2>&1
    fi
    
    # 下载GOST
    cd /tmp
    echo -e "${Info} 下载GOST程序..."
    if ! wget -q --timeout=30 -O gost.gz "https://github.com/ginuerzh/gost/releases/download/v${ct_new_ver}/gost-linux-${arch}-${ct_new_ver}.gz"; then
        echo -e "${Info} 使用镜像源下载..."
        if ! wget -q --timeout=30 -O gost.gz "https://mirror.ghproxy.com/https://github.com/ginuerzh/gost/releases/download/v${ct_new_ver}/gost-linux-${arch}-${ct_new_ver}.gz"; then
            echo -e "${Error} GOST下载失败"
            exit 1
        fi
    fi
    
    gunzip gost.gz
    chmod +x gost
    mv gost /usr/bin/gost
    
    # 创建systemd服务
    cat > /etc/systemd/system/gost.service << 'EOF'
[Unit]
Description=GOST
After=network.target

[Service]
Type=simple
ExecStartPre=/usr/local/bin/gost-expire-check.sh
ExecStart=/usr/bin/gost -C /etc/gost/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable gost
    
    # 创建独立的到期检查脚本
    create_expire_check_script
    
    # 创建流量统计脚本
    create_traffic_monitor_script
    
    # 设置定时任务 - 每小时检查到期，每5分钟统计流量
    echo "0 * * * * root /usr/local/bin/gost-expire-check.sh >/dev/null 2>&1" > /etc/cron.d/gost-expire
    echo "*/5 * * * * root /usr/local/bin/gost-traffic-monitor.sh >/dev/null 2>&1" >> /etc/cron.d/gost-expire
    echo "0 0 * * * root /usr/local/bin/gost-traffic-reset.sh daily >/dev/null 2>&1" >> /etc/cron.d/gost-expire
    echo "0 0 1 * * root /usr/local/bin/gost-traffic-reset.sh monthly >/dev/null 2>&1" >> /etc/cron.d/gost-expire
    
    echo -e "${Info} GOST安装完成"
}

create_expire_check_script() {
    cat > /usr/local/bin/gost-expire-check.sh << 'EOF'
#!/bin/bash
# 独立的到期检查脚本

EXPIRES_FILE="/etc/gost/expires.txt"
RAW_CONF="/etc/gost/rawconf"
GOST_CONF="/etc/gost/config.json"

[ ! -f "$EXPIRES_FILE" ] && exit 0

current_time=$(date +%s)
expired_ports=""
need_rebuild=false

while IFS=: read -r port expire_date; do
    if [ "$expire_date" != "永久" ] && [ "$expire_date" -le "$current_time" ]; then
        expired_ports="$expired_ports $port"
        need_rebuild=true
    fi
done < "$EXPIRES_FILE"

if [ "$need_rebuild" = true ]; then
    for port in $expired_ports; do
        # 删除过期规则
        sed -i "/\/${port}#/d" "$RAW_CONF"
        sed -i "/^${port}:/d" "$EXPIRES_FILE"
        sed -i "/^${port}:/d" "/etc/gost/remarks.txt"
        # 清理iptables规则
        iptables -D INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null
        iptables -D INPUT -p udp --dport $port -j ACCEPT 2>/dev/null
        iptables -t mangle -F GOST_$port 2>/dev/null
        iptables -t mangle -X GOST_$port 2>/dev/null
        echo "[$(date)] 端口 $port 的转发规则已过期并删除" >> /var/log/gost.log
    done
    
    # 重建配置
    if [ ! -f "$RAW_CONF" ] || [ ! -s "$RAW_CONF" ]; then
        echo '{"Debug":false,"Retries":0,"ServeNodes":[]}' > "$GOST_CONF"
    else
        echo '{"Debug":false,"Retries":0,"ServeNodes":[' > "$GOST_CONF"
        count_line=$(wc -l < "$RAW_CONF")
        i=1
        
        while IFS= read -r line; do
            port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
            target=$(echo "$line" | cut -d'#' -f2)
            target_port=$(echo "$line" | cut -d'#' -f3)
            
            echo -n "        \"tcp://:$port/$target:$target_port\",\"udp://:$port/$target:$target_port\"" >> "$gost_conf_path"
            
            if [ "$i" -lt "$count_line" ]; then
                echo "," >> "$gost_conf_path"
            else
                echo "" >> "$gost_conf_path"
            fi
            ((i++))
        done < "$raw_conf_path"
        
        echo "    ]" >> "$gost_conf_path"
        echo "}" >> "$gost_conf_path"
    fi
    
    systemctl restart gost >/dev/null 2>&1
}

show_traffic_details() {
    echo -e "${Blue_font_prefix}================================ 流量统计详情 ================================${Font_color_suffix}"
    if [ ! -f "$raw_conf_path" ] || [ ! -s "$raw_conf_path" ]; then
        echo -e "${Warning} 暂无转发规则"
        echo
        return
    fi

    printf "${Green_font_prefix}%-8s %-15s %-15s %-15s %-12s${Font_color_suffix}\n" \
        "端口" "今日流量" "本月流量" "总流量" "当前速率"
    echo -e "${Blue_font_prefix}------------------------------------------------------------------------------${Font_color_suffix}"
    
    local total_today=0
    local total_month=0
    local total_all=0
    
    while IFS= read -r line; do
        local port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
        
        # 获取流量信息
        local traffic_data=$(grep "^$port:" "$traffic_path" 2>/dev/null)
        if [ -n "$traffic_data" ]; then
            local total=$(echo "$traffic_data" | cut -d: -f2)
            local today=$(echo "$traffic_data" | cut -d: -f3)
            local month=$(echo "$traffic_data" | cut -d: -f4)
            
            # 获取实时速率
            local traffic_info=$(get_port_traffic "$port")
            local speed=$(echo "$traffic_info" | cut -d: -f3)
            
            total_today=$((total_today + today))
            total_month=$((total_month + month))
            total_all=$((total_all + total))
            
            printf "%-8s %-15s %-15s %-15s %-12s\n" \
                "$port" \
                "$(format_bytes $today)" \
                "$(format_bytes $month)" \
                "$(format_bytes $total)" \
                "$(format_bytes $speed)/s"
        else
            printf "%-8s %-15s %-15s %-15s %-12s\n" \
                "$port" "0B" "0B" "0B" "0B/s"
        fi
    done < "$raw_conf_path"
    
    echo -e "${Blue_font_prefix}------------------------------------------------------------------------------${Font_color_suffix}"
    printf "${Yellow_font_prefix}%-8s %-15s %-15s %-15s${Font_color_suffix}\n" \
        "总计" \
        "$(format_bytes $total_today)" \
        "$(format_bytes $total_month)" \
        "$(format_bytes $total_all)"
    echo
}

manage_forwards() {
    while true; do
        show_header
        # 先检查并清理过期规则
        /usr/local/bin/gost-expire-check.sh 2>/dev/null
        show_forwards_list
        echo -e "${Green_font_prefix}=================== 转发管理 ===================${Font_color_suffix}"
        echo -e "${Green_font_prefix}1.${Font_color_suffix} 新增转发规则"
        echo -e "${Green_font_prefix}2.${Font_color_suffix} 删除转发规则"
        echo -e "${Green_font_prefix}3.${Font_color_suffix} 查看流量详情"
        echo -e "${Green_font_prefix}4.${Font_color_suffix} 立即清理过期规则"
        echo -e "${Green_font_prefix}5.${Font_color_suffix} 重启GOST服务"
        echo -e "${Green_font_prefix}0.${Font_color_suffix} 返回主菜单"
        echo
        read -p "请选择操作: " choice
        
        case $choice in
            1) add_forward_rule ;;
            2) delete_forward_rule ;;
            3) 
                clear
                show_header
                show_traffic_details
                read -p "按Enter返回..."
                ;;
            4) 
                /usr/local/bin/gost-expire-check.sh
                echo -e "${Info} 已清理过期规则"
                sleep 2
                ;;
            5) 
                systemctl restart gost && echo -e "${Info} 服务已重启"
                # 重新初始化iptables规则
                if [ -f "$raw_conf_path" ] && [ -s "$raw_conf_path" ]; then
                    while IFS= read -r line; do
                        port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
                        setup_iptables_for_port "$port"
                    done < "$raw_conf_path"
                fi
                sleep 2
                ;;
            0) break ;;
            *) echo -e "${Error} 无效选择" && sleep 2 ;;
        esac
    done
}

traffic_management() {
    while true; do
        show_header
        echo -e "${Green_font_prefix}=================== 流量管理 ===================${Font_color_suffix}"
        echo -e "${Green_font_prefix}1.${Font_color_suffix} 查看流量统计"
        echo -e "${Green_font_prefix}2.${Font_color_suffix} 重置今日流量"
        echo -e "${Green_font_prefix}3.${Font_color_suffix} 重置本月流量"
        echo -e "${Green_font_prefix}4.${Font_color_suffix} 立即更新流量数据"
        echo -e "${Green_font_prefix}5.${Font_color_suffix} 导出流量报表"
        echo -e "${Green_font_prefix}0.${Font_color_suffix} 返回主菜单"
        echo
        read -p "请选择操作: " choice
        
        case $choice in
            1) 
                clear
                show_header
                show_traffic_details
                read -p "按Enter返回..."
                ;;
            2) 
                /usr/local/bin/gost-traffic-reset.sh daily
                echo -e "${Info} 今日流量已重置"
                sleep 2
                ;;
            3) 
                /usr/local/bin/gost-traffic-reset.sh monthly
                echo -e "${Info} 本月流量已重置"
                sleep 2
                ;;
            4) 
                /usr/local/bin/gost-traffic-monitor.sh
                echo -e "${Info} 流量数据已更新"
                sleep 2
                ;;
            5)
                report_file="/tmp/gost_traffic_report_$(date +%Y%m%d_%H%M%S).txt"
                echo "GOST流量统计报表 - $(date '+%Y-%m-%d %H:%M:%S')" > "$report_file"
                echo "================================================" >> "$report_file"
                echo "" >> "$report_file"
                
                if [ -f "$raw_conf_path" ] && [ -s "$raw_conf_path" ]; then
                    while IFS= read -r line; do
                        port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
                        target=$(echo "$line" | cut -d'#' -f2)
                        target_port=$(echo "$line" | cut -d'#' -f3)
                        remark=$(grep "^${port}:" "$remarks_path" 2>/dev/null | cut -d':' -f2- || echo "无")
                        
                        traffic_data=$(grep "^$port:" "$traffic_path" 2>/dev/null)
                        if [ -n "$traffic_data" ]; then
                            total=$(echo "$traffic_data" | cut -d: -f2)
                            today=$(echo "$traffic_data" | cut -d: -f3)
                            month=$(echo "$traffic_data" | cut -d: -f4)
                            
                            echo "端口: $port -> $target:$target_port" >> "$report_file"
                            echo "备注: $remark" >> "$report_file"
                            echo "今日流量: $(format_bytes $today)" >> "$report_file"
                            echo "本月流量: $(format_bytes $month)" >> "$report_file"
                            echo "总流量: $(format_bytes $total)" >> "$report_file"
                            echo "------------------------------------------------" >> "$report_file"
                        fi
                    done < "$raw_conf_path"
                fi
                
                echo -e "${Info} 报表已导出到: $report_file"
                sleep 3
                ;;
            0) break ;;
            *) echo -e "${Error} 无效选择" && sleep 2 ;;
        esac
    done
}

system_management() {
    while true; do
        show_header
        echo -e "${Green_font_prefix}=================== 系统管理 ===================${Font_color_suffix}"
        echo -e "${Green_font_prefix}1.${Font_color_suffix} 查看服务状态"
        echo -e "${Green_font_prefix}2.${Font_color_suffix} 启动GOST服务"
        echo -e "${Green_font_prefix}3.${Font_color_suffix} 停止GOST服务"
        echo -e "${Green_font_prefix}4.${Font_color_suffix} 重启GOST服务"
        echo -e "${Green_font_prefix}5.${Font_color_suffix} 查看服务日志"
        echo -e "${Green_font_prefix}6.${Font_color_suffix} 备份配置"
        echo -e "${Green_font_prefix}7.${Font_color_suffix} 恢复配置"
        echo -e "${Green_font_prefix}8.${Font_color_suffix} 卸载GOST"
        echo -e "${Green_font_prefix}0.${Font_color_suffix} 返回主菜单"
        echo
        read -p "请选择操作: " choice
        
        case $choice in
            1) 
                echo -e "${Info} 服务状态: $(systemctl is-active gost 2>/dev/null || echo '未运行')"
                echo -e "${Info} 开机自启: $(systemctl is-enabled gost 2>/dev/null || echo '未设置')"
                echo -e "${Info} 配置文件: $gost_conf_path"
                echo -e "${Info} 规则文件: $raw_conf_path"
                echo -e "${Info} 流量数据: $traffic_path"
                
                # 显示定时任务状态
                if [ -f /etc/cron.d/gost-expire ]; then
                    echo -e "${Info} 定时任务: 已配置"
                    echo -e "  - 到期检查: 每小时执行"
                    echo -e "  - 流量统计: 每5分钟执行"
                else
                    echo -e "${Warning} 定时任务: 未配置"
                fi
                
                read -p "按Enter继续..."
                ;;
            2) 
                systemctl start gost && echo -e "${Info} 服务已启动"
                sleep 2
                ;;
            3) 
                systemctl stop gost && echo -e "${Info} 服务已停止"
                sleep 2
                ;;
            4) 
                systemctl restart gost && echo -e "${Info} 服务已重启"
                sleep 2
                ;;
            5)
                echo -e "${Info} 最近50行日志:"
                journalctl -u gost -n 50 --no-pager
                read -p "按Enter继续..."
                ;;
            6)
                backup_dir="/root/gost_backup_$(date +%Y%m%d_%H%M%S)"
                mkdir -p "$backup_dir"
                cp -r /etc/gost/* "$backup_dir/" 2>/dev/null
                echo -e "${Info} 配置已备份到: $backup_dir"
                sleep 2
                ;;
            7)
                echo -e "${Info} 可用的备份:"
                ls -d /root/gost_backup_* 2>/dev/null || echo "无备份"
                read -p "请输入备份目录名(如gost_backup_20240101_120000): " backup_name
                if [ -d "/root/$backup_name" ]; then
                    systemctl stop gost
                    cp -r "/root/$backup_name/"* /etc/gost/
                    systemctl start gost
                    echo -e "${Info} 配置已恢复"
                else
                    echo -e "${Error} 备份目录不存在"
                fi
                sleep 2
                ;;
            8)
                read -p "确认卸载GOST？所有配置和数据将被删除！(y/N): " confirm
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    systemctl stop gost 2>/dev/null
                    systemctl disable gost 2>/dev/null
                    
                    # 清理iptables规则
                    if [ -f "$raw_conf_path" ] && [ -s "$raw_conf_path" ]; then
                        while IFS= read -r line; do
                            port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
                            remove_iptables_for_port "$port"
                        done < "$raw_conf_path"
                    fi
                    
                    rm -f /usr/bin/gost /etc/systemd/system/gost.service /usr/bin/g
                    rm -rf /etc/gost
                    rm -f /usr/local/bin/gost-manager.sh
                    rm -f /usr/local/bin/gost-expire-check.sh
                    rm -f /usr/local/bin/gost-traffic-monitor.sh
                    rm -f /usr/local/bin/gost-traffic-reset.sh
                    rm -f /etc/cron.d/gost-expire
                    
                    echo -e "${Info} GOST已完全卸载"
                    exit 0
                fi
                ;;
            0) break ;;
            *) echo -e "${Error} 无效选择" && sleep 2 ;;
        esac
    done
}

main_menu() {
    while true; do
        show_header
        get_system_info
        echo -e "${Green_font_prefix}==================== 主菜单 ====================${Font_color_suffix}"
        echo -e "${Green_font_prefix}1.${Font_color_suffix} 转发管理"
        echo -e "${Green_font_prefix}2.${Font_color_suffix} 流量管理"
        echo -e "${Green_font_prefix}3.${Font_color_suffix} 系统管理"
        echo -e "${Green_font_prefix}0.${Font_color_suffix} 退出程序"
        echo -e "${Blue_font_prefix}=================================================${Font_color_suffix}"
        echo -e "${Yellow_font_prefix}提示: 使用命令 'g' 可快速打开此面板${Font_color_suffix}"
        echo
        read -p "请选择操作 [0-3]: " choice
        
        case $choice in
            1) manage_forwards ;;
            2) traffic_management ;;
            3) system_management ;;
            0) echo -e "${Info} 感谢使用!" && exit 0 ;;
            *) echo -e "${Error} 无效选择" && sleep 2 ;;
        esac
    done
}

main() {
    check_root
    
    case "${1:-}" in
        --menu)
            init_config
            main_menu
            ;;
        *)
            if ! command -v gost >/dev/null 2>&1; then
                echo -e "${Info} 检测到GOST未安装，开始安装..."
                install_gost
                create_shortcut
                init_config
                echo -e "${Info} 安装完成！现在可以使用 'g' 命令打开管理面板"
                echo -e "${Info} 正在打开管理面板..."
                sleep 2
                main_menu
            else
                if [ ! -f "/usr/bin/g" ]; then
                    create_shortcut
                fi
                init_config
                # 立即执行一次到期检查
                /usr/local/bin/gost-expire-check.sh 2>/dev/null
                main_menu
            fi
            ;;
    esac
}

# 执行主函数
main "$@"\"" >> "$GOST_CONF"
            
            if [ "$i" -lt "$count_line" ]; then
                echo "," >> "$GOST_CONF"
            else
                echo "" >> "$GOST_CONF"
            fi
            ((i++))
        done < "$RAW_CONF"
        
        echo "    ]" >> "$GOST_CONF"
        echo "}" >> "$GOST_CONF"
    fi
    
    systemctl restart gost >/dev/null 2>&1
fi
EOF
    chmod +x /usr/local/bin/gost-expire-check.sh
}

create_traffic_monitor_script() {
    cat > /usr/local/bin/gost-traffic-monitor.sh << 'EOF'
#!/bin/bash
# 流量统计脚本

TRAFFIC_DB="/etc/gost/traffic.db"
TRAFFIC_HISTORY="/etc/gost/traffic_history.db"
RAW_CONF="/etc/gost/rawconf"

[ ! -f "$RAW_CONF" ] && exit 0

# 创建流量数据文件
touch "$TRAFFIC_DB" "$TRAFFIC_HISTORY"

# 获取当前时间戳
current_time=$(date +%s)
today=$(date +%Y%m%d)
month=$(date +%Y%m)

# 读取所有端口的流量
while IFS= read -r line; do
    port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
    
    # 获取iptables流量统计
    tcp_bytes=$(iptables -t mangle -nvxL GOST_$port 2>/dev/null | awk '/ACCEPT/{sum+=$2}END{print sum+0}')
    udp_bytes=$(iptables -t mangle -nvxL GOST_$port 2>/dev/null | awk '/ACCEPT.*udp/{sum+=$2}END{print sum+0}')
    total_bytes=$((tcp_bytes + udp_bytes))
    
    # 读取历史数据
    old_data=$(grep "^$port:" "$TRAFFIC_DB" 2>/dev/null)
    if [ -n "$old_data" ]; then
        old_total=$(echo "$old_data" | cut -d: -f2)
        old_today=$(echo "$old_data" | cut -d: -f3)
        old_month=$(echo "$old_data" | cut -d: -f4)
        old_date=$(echo "$old_data" | cut -d: -f5)
        old_month_date=$(echo "$old_data" | cut -d: -f6)
        
        # 检查是否需要重置日流量
        if [ "$old_date" != "$today" ]; then
            old_today=0
        fi
        
        # 检查是否需要重置月流量
        if [ "$old_month_date" != "$month" ]; then
            old_month=0
        fi
        
        # 计算增量
        if [ "$total_bytes" -ge "$old_total" ]; then
            increment=$((total_bytes - old_total))
        else
            # iptables计数器可能被重置
            increment=$total_bytes
        fi
        
        new_today=$((old_today + increment))
        new_month=$((old_month + increment))
        
        # 更新数据
        sed -i "/^$port:/d" "$TRAFFIC_DB"
        echo "$port:$total_bytes:$new_today:$new_month:$today:$month:$current_time" >> "$TRAFFIC_DB"
    else
        # 新端口
        echo "$port:$total_bytes:$total_bytes:$total_bytes:$today:$month:$current_time" >> "$TRAFFIC_DB"
    fi
done < "$RAW_CONF"

# 保存历史记录
cp "$TRAFFIC_DB" "$TRAFFIC_HISTORY.$(date +%Y%m%d%H%M)"
# 只保留最近100个历史文件
ls -t "$TRAFFIC_HISTORY".* 2>/dev/null | tail -n +101 | xargs rm -f 2>/dev/null
EOF
    chmod +x /usr/local/bin/gost-traffic-monitor.sh
    
    # 创建流量重置脚本
    cat > /usr/local/bin/gost-traffic-reset.sh << 'EOF'
#!/bin/bash
# 流量重置脚本

TRAFFIC_DB="/etc/gost/traffic.db"
reset_type="$1"

if [ "$reset_type" = "daily" ]; then
    # 重置日流量
    while IFS=: read -r port total today month date month_date time; do
        echo "$port:$total:0:$month:$(date +%Y%m%d):$month_date:$time"
    done < "$TRAFFIC_DB" > "$TRAFFIC_DB.tmp"
    mv "$TRAFFIC_DB.tmp" "$TRAFFIC_DB"
elif [ "$reset_type" = "monthly" ]; then
    # 重置月流量
    while IFS=: read -r port total today month date month_date time; do
        echo "$port:$total:$today:0:$date:$(date +%Y%m):$time"
    done < "$TRAFFIC_DB" > "$TRAFFIC_DB.tmp"
    mv "$TRAFFIC_DB.tmp" "$TRAFFIC_DB"
fi
EOF
    chmod +x /usr/local/bin/gost-traffic-reset.sh
}

setup_iptables_for_port() {
    local port=$1
    
    # 创建专用链用于流量统计
    iptables -t mangle -N GOST_$port 2>/dev/null
    
    # 添加规则到PREROUTING链
    iptables -t mangle -C PREROUTING -p tcp --dport $port -j GOST_$port 2>/dev/null || \
        iptables -t mangle -A PREROUTING -p tcp --dport $port -j GOST_$port
    iptables -t mangle -C PREROUTING -p udp --dport $port -j GOST_$port 2>/dev/null || \
        iptables -t mangle -A PREROUTING -p udp --dport $port -j GOST_$port
    
    # 在专用链中添加ACCEPT规则用于计数
    iptables -t mangle -C GOST_$port -j ACCEPT 2>/dev/null || \
        iptables -t mangle -A GOST_$port -j ACCEPT
}

remove_iptables_for_port() {
    local port=$1
    
    # 删除PREROUTING链中的规则
    iptables -t mangle -D PREROUTING -p tcp --dport $port -j GOST_$port 2>/dev/null
    iptables -t mangle -D PREROUTING -p udp --dport $port -j GOST_$port 2>/dev/null
    
    # 删除专用链
    iptables -t mangle -F GOST_$port 2>/dev/null
    iptables -t mangle -X GOST_$port 2>/dev/null
}

format_bytes() {
    local bytes=$1
    if [ "$bytes" -lt 1024 ]; then
        echo "${bytes}B"
    elif [ "$bytes" -lt 1048576 ]; then
        echo "$(echo "scale=2; $bytes/1024" | bc)KB"
    elif [ "$bytes" -lt 1073741824 ]; then
        echo "$(echo "scale=2; $bytes/1048576" | bc)MB"
    else
        echo "$(echo "scale=2; $bytes/1073741824" | bc)GB"
    fi
}

get_port_traffic() {
    local port=$1
    local traffic_data=$(grep "^$port:" "$traffic_path" 2>/dev/null)
    
    if [ -n "$traffic_data" ]; then
        local today=$(echo "$traffic_data" | cut -d: -f3)
        local month=$(echo "$traffic_data" | cut -d: -f4)
        local last_update=$(echo "$traffic_data" | cut -d: -f7)
        
        # 计算速率 (最近5分钟的平均速率)
        local current_time=$(date +%s)
        local time_diff=$((current_time - last_update))
        if [ "$time_diff" -gt 0 ] && [ "$time_diff" -lt 600 ]; then
            local current_bytes=$(iptables -t mangle -nvxL GOST_$port 2>/dev/null | awk '/ACCEPT/{sum+=$2}END{print sum+0}')
            local old_bytes=$(echo "$traffic_data" | cut -d: -f2)
            local bytes_diff=$((current_bytes - old_bytes))
            if [ "$bytes_diff" -lt 0 ]; then bytes_diff=0; fi
            local speed=$((bytes_diff / time_diff))
        else
            local speed=0
        fi
        
        echo "$today:$month:$speed"
    else
        echo "0:0:0"
    fi
}

create_shortcut() {
    echo -e "${Info} 创建快捷命令..."
    
    if is_oneclick_install; then
        # 在线安装模式
        if wget -q -O /usr/local/bin/gost-manager.sh "https://raw.githubusercontent.com/xmg0828-01/gost/main/gost.sh"; then
            chmod +x /usr/local/bin/gost-manager.sh
        else
            cat > /usr/local/bin/gost-manager.sh << 'EOF'
#!/bin/bash
bash <(curl -sSL https://raw.githubusercontent.com/xmg0828-01/gost/main/gost.sh) --menu
EOF
            chmod +x /usr/local/bin/gost-manager.sh
        fi
    else
        # 本地安装模式
        cp "$0" /usr/local/bin/gost-manager.sh
        chmod +x /usr/local/bin/gost-manager.sh
    fi
    
    ln -sf /usr/local/bin/gost-manager.sh /usr/bin/g
    echo -e "${Info} 快捷命令 'g' 创建成功"
}

init_config() {
    mkdir -p /etc/gost
    touch /etc/gost/{rawconf,remarks.txt,expires.txt,traffic.db,traffic_history.db}
    [ ! -f "$gost_conf_path" ] && echo '{"Debug":false,"Retries":0,"ServeNodes":[]}' > "$gost_conf_path"
    
    # 初始化已有端口的iptables规则
    if [ -f "$raw_conf_path" ] && [ -s "$raw_conf_path" ]; then
        while IFS= read -r line; do
            port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
            setup_iptables_for_port "$port"
        done < "$raw_conf_path"
    fi
}

show_header() {
    clear
    echo -e "${Blue_font_prefix}======================================================${Font_color_suffix}"
    echo -e "${Green_font_prefix}          GOST 增强版管理面板 v${shell_version}${Font_color_suffix}"
    echo -e "${Blue_font_prefix}======================================================${Font_color_suffix}"
    echo -e "${Yellow_font_prefix}功能: 转发管理 | 到期时间 | 流量统计 | 备注信息${Font_color_suffix}"
    echo -e "${Blue_font_prefix}======================================================${Font_color_suffix}"
    echo
}

check_expired_rules() {
    local expired_count=0
    local current_date=$(date +%s)
    
    if [ -f "$expires_path" ]; then
        while IFS=: read -r port expire_date; do
            if [ "$expire_date" != "永久" ] && [ "$expire_date" -le "$current_date" ]; then
                ((expired_count++))
            fi
        done < "$expires_path"
    fi
    
    echo "$expired_count"
}

format_expire_date() {
    local expire_timestamp=$1
    if [ "$expire_timestamp" = "永久" ]; then
        echo "永久"
    else
        local current=$(date +%s)
        local seconds_left=$((expire_timestamp - current))
        
        if [ "$seconds_left" -lt 0 ]; then
            echo "已过期"
        elif [ "$seconds_left" -lt 3600 ]; then
            echo "$((seconds_left / 60))分钟后"
        elif [ "$seconds_left" -lt 86400 ]; then
            echo "$((seconds_left / 3600))小时后"
        else
            echo "$((seconds_left / 86400))天后"
        fi
    fi
}

get_system_info() {
    if command -v gost >/dev/null 2>&1; then
        gost_status=$(systemctl is-active gost 2>/dev/null || echo "未运行")
        gost_version=$(gost -V 2>/dev/null | awk '{print $2}' || echo "未知")
    else
        gost_status="未安装"
        gost_version="未安装"
    fi
    
    active_rules=$(wc -l < "$raw_conf_path" 2>/dev/null || echo "0")
    expired_rules=$(check_expired_rules)
    
    # 计算总流量
    total_traffic=0
    if [ -f "$traffic_path" ]; then
        while IFS=: read -r port total rest; do
            total_traffic=$((total_traffic + total))
        done < "$traffic_path"
    fi
    
    echo -e "${Info} 服务状态: ${gost_status} | 版本: ${gost_version} | 总流量: $(format_bytes $total_traffic)"
    echo -e "${Info} 活跃规则: ${active_rules} | 过期规则: ${expired_rules}"
    echo
}

show_forwards_list() {
    echo -e "${Blue_font_prefix}================================ 转发规则列表 ================================${Font_color_suffix}"
    if [ ! -f "$raw_conf_path" ] || [ ! -s "$raw_conf_path" ]; then
        echo -e "${Warning} 暂无转发规则"
        echo
        return
    fi

    printf "${Green_font_prefix}%-4s %-8s %-20s %-10s %-12s %-10s${Font_color_suffix}\n" \
        "ID" "端口" "目标地址" "备注" "到期时间" "今日流量"
    echo -e "${Blue_font_prefix}------------------------------------------------------------------------------${Font_color_suffix}"
    
    local id=1
    while IFS= read -r line; do
        local port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
        local target=$(echo "$line" | cut -d'#' -f2)
        local target_port=$(echo "$line" | cut -d'#' -f3)
        local remark=$(grep "^${port}:" "$remarks_path" 2>/dev/null | cut -d':' -f2- || echo "无")
        local expire_info=$(grep "^${port}:" "$expires_path" 2>/dev/null | cut -d':' -f2- || echo "永久")
        local expire_display=$(format_expire_date "$expire_info")
        
        # 获取流量信息
        local traffic_info=$(get_port_traffic "$port")
        local today_traffic=$(echo "$traffic_info" | cut -d: -f1)
        local today_display=$(format_bytes "$today_traffic")
        
        # 截断过长的内容
        [ ${#remark} -gt 8 ] && remark="${remark:0:8}.."
        [ ${#target} -gt 12 ] && target_display="${target:0:10}.." || target_display="$target"
        
        # 根据到期状态设置颜色
        if [ "$expire_display" = "已过期" ]; then
            expire_color="${Red_font_prefix}"
        elif [[ "$expire_display" == *"小时后"* ]] || [[ "$expire_display" == *"分钟后"* ]]; then
            expire_color="${Yellow_font_prefix}"
        else
            expire_color=""
        fi
        
        printf "%-4s %-8s %-20s %-10s ${expire_color}%-12s${Font_color_suffix} %-10s\n" \
            "$id" "$port" "${target_display}:${target_port}" "$remark" "$expire_display" "$today_display"
        
        ((id++))
    done < "$raw_conf_path"
    echo
}

add_forward_rule() {
    echo -e "${Info} 添加TCP+UDP转发规则"
    read -p "本地监听端口: " local_port
    read -p "目标IP地址: " target_ip  
    read -p "目标端口: " target_port
    read -p "备注信息 (可选): " remark
    
    echo -e "${Info} 设置到期时间:"
    echo "1) 永久有效"
    echo "2) 自定义小时数"
    echo "3) 自定义天数"
    read -p "请选择 [1-3]: " expire_choice
    
    local expire_timestamp="永久"
    case $expire_choice in
        2)
            read -p "请输入有效小时数: " hours
            if [[ $hours =~ ^[0-9]+$ ]] && [ "$hours" -gt 0 ]; then
                expire_timestamp=$(date -d "+${hours} hours" +%s)
                echo -e "${Info} 规则将在 ${hours} 小时后到期"
            else
                echo -e "${Warning} 小时数格式错误，设置为永久有效"
                expire_timestamp="永久"
            fi
            ;;
        3)
            read -p "请输入有效天数: " days
            if [[ $days =~ ^[0-9]+$ ]] && [ "$days" -gt 0 ]; then
                expire_timestamp=$(date -d "+${days} days" +%s)
                echo -e "${Info} 规则将在 ${days} 天后到期"
            else
                echo -e "${Warning} 天数格式错误，设置为永久有效"
                expire_timestamp="永久"
            fi
            ;;
        *)
            expire_timestamp="永久"
            ;;
    esac
    
    if [[ ! $local_port =~ ^[0-9]+$ ]] || [[ ! $target_port =~ ^[0-9]+$ ]]; then
        echo -e "${Error} 端口必须为数字"
        sleep 2
        return
    fi
    
    if grep -q "/${local_port}#" "$raw_conf_path" 2>/dev/null; then
        echo -e "${Error} 端口 $local_port 已被使用"
        sleep 2
        return
    fi
    
    echo "nonencrypt/${local_port}#${target_ip}#${target_port}" >> "$raw_conf_path"
    [ -n "$remark" ] && echo "${local_port}:${remark}" >> "$remarks_path"
    echo "${local_port}:${expire_timestamp}" >> "$expires_path"
    
    # 设置iptables规则用于流量统计
    setup_iptables_for_port "$local_port"
    
    rebuild_config
    echo -e "${Info} 转发规则已添加"
    echo -e "${Info} 端口: ${local_port} -> ${target_ip}:${target_port}"
    echo -e "${Info} 备注: ${remark:-无}"
    echo -e "${Info} 到期: $(format_expire_date "$expire_timestamp")"
    sleep 2
}

delete_forward_rule() {
    if [ ! -f "$raw_conf_path" ] || [ ! -s "$raw_conf_path" ]; then
        echo -e "${Warning} 暂无转发规则"
        sleep 2
        return
    fi
    
    read -p "请输入要删除的规则ID: " rule_id
    
    if ! [[ $rule_id =~ ^[0-9]+$ ]] || [ "$rule_id" -lt 1 ]; then
        echo -e "${Error} 无效的规则ID"
        sleep 2
        return
    fi
    
    local line=$(sed -n "${rule_id}p" "$raw_conf_path")
    if [ -z "$line" ]; then
        echo -e "${Error} 规则ID不存在"
        sleep 2
        return
    fi
    
    local port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
    
    sed -i "${rule_id}d" "$raw_conf_path"
    sed -i "/^${port}:/d" "$remarks_path" 2>/dev/null
    sed -i "/^${port}:/d" "$expires_path" 2>/dev/null
    sed -i "/^${port}:/d" "$traffic_path" 2>/dev/null
    
    # 清理iptables规则
    remove_iptables_for_port "$port"
    
    rebuild_config
    echo -e "${Info} 规则已删除 (端口: ${port})"
    sleep 2
}

rebuild_config() {
    if [ ! -f "$raw_conf_path" ] || [ ! -s "$raw_conf_path" ]; then
        echo '{"Debug":false,"Retries":0,"ServeNodes":[]}' > "$gost_conf_path"
    else
        echo '{"Debug":false,"Retries":0,"ServeNodes":[' > "$gost_conf_path"
        local count_line=$(wc -l < "$raw_conf_path")
        local i=1
        
        while IFS= read -r line; do
            local port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
            local target=$(echo "$line" | cut -d'#' -f2)
            local target_port=$(echo "$line" | cut -d'#' -f3)
            
            echo -n "        \"tcp://:$port/$target:$target_port\",\"udp://:$port/$target:$target_port
